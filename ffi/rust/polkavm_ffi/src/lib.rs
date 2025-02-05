use std::mem;
use std::ptr;
use std::slice;
use std::sync::Once;

use polkavm::{
  BackendKind, Config, Engine, GasMeteringKind, InterruptKind, Module,
  ModuleConfig, ProgramBlob, ProgramCounter, Reg,
};

/// Represents a memory page in the PolkaVM execution environment
#[repr(C)]
#[derive(Debug)]
pub struct MemoryPage {
  address: u32,
  data: *mut u8,
  size: usize,
  is_writable: bool,
}

/// Possible execution status codes returned by the VM
#[repr(C)]
#[derive(Debug, PartialEq)]
pub enum ExecutionStatus {
  Success = 0,
  EngineError = 1,
  ProgramError = 2,
  ModuleError = 3,
  InstantiationError = 4,
  MemoryError = 5,
  Trap = 6,
  OutOfGas = 7,
  Segfault = 8,
  InstanceRunError = 9,
  UnknownError = 10,
}

/// Contains the complete result of a PolkaVM execution
#[repr(C)]
#[derive(Debug)]
pub struct ExecutionResult {
  status: ExecutionStatus,
  final_pc: u32,
  pages: *mut MemoryPage,
  page_count: usize,
  registers: [u64; 13], // 12 GP registers + PC
  gas_remaining: i64,
  segfault_address: u32,
}

static INIT: Once = Once::new();

/// Initializes the logging system. This function is thread-safe and will only
/// initialize logging once, even if called multiple times.
#[no_mangle]
pub extern "C" fn init_logging() {
  INIT.call_once(|| {
    env_logger::init();
  });
}

/// Creates an error result with default values
fn create_error_result(
  status: ExecutionStatus,
  gas_limit: u64,
) -> ExecutionResult {
  ExecutionResult {
    status,
    final_pc: 0,
    pages: ptr::null_mut(),
    page_count: 0,
    registers: [0; 13],
    gas_remaining: gas_limit as i64,
    segfault_address: 0,
  }
}

/// Executes bytecode in the PolkaVM environment
///
/// # Safety
///
/// This function is unsafe because it:
/// - Accepts raw pointers as input
/// - Performs raw memory operations
/// - Returns unmanaged memory that must be freed using free_execution_result
///
/// # Parameters
///
/// * `bytecode` - Pointer to the bytecode to execute
/// * `bytecode_len` - Length of the bytecode
/// * `initial_pages` - Array of memory pages to initialize
/// * `page_count` - Number of memory pages
/// * `initial_registers` - Initial values for VM registers
/// * `gas_limit` - Maximum gas available for execution
#[no_mangle]
pub unsafe extern "C" fn execute_pvm(
  bytecode: *const u8,
  bytecode_len: usize,
  initial_pages: *const MemoryPage,
  page_count: usize,
  initial_registers: *const u64,
  gas_limit: u64,
) -> ExecutionResult {
  let raw_bytes = slice::from_raw_parts(bytecode, bytecode_len);
  let pages = slice::from_raw_parts(initial_pages, page_count);

  // Set up engine configuration
  let mut config = Config::new();
  config.set_backend(Some(BackendKind::Interpreter));
  config.set_allow_dynamic_paging(true);

  // Initialize engine
  let engine = match Engine::new(&config) {
    Ok(e) => e,
    Err(_) => {
      return create_error_result(ExecutionStatus::EngineError, gas_limit)
    }
  };

  // Parse program blob
  let blob = match ProgramBlob::parse(raw_bytes.to_vec().into()) {
    Ok(b) => b,
    Err(_) => {
      return create_error_result(ExecutionStatus::ProgramError, gas_limit)
    }
  };

  // Configure and create module
  let mut module_config = ModuleConfig::default();
  module_config.set_strict(true);
  module_config.set_gas_metering(Some(GasMeteringKind::Sync));
  module_config.set_dynamic_paging(true);
  module_config.set_step_tracing(true);

  let module = match Module::from_blob(&engine, &module_config, blob) {
    Ok(m) => m,
    Err(_) => {
      return create_error_result(ExecutionStatus::ModuleError, gas_limit)
    }
  };

  // Instantiate module
  let mut instance = match module.instantiate() {
    Ok(i) => i,
    Err(_) => {
      return create_error_result(
        ExecutionStatus::InstantiationError,
        gas_limit,
      )
    }
  };

  // Initialize memory pages
  for page in pages {
    let page_data = slice::from_raw_parts(page.data, page.size);
    if instance.write_memory(page.address, page_data).is_err() {
      return create_error_result(ExecutionStatus::MemoryError, gas_limit);
    }

    if !page.is_writable
      && instance
        .protect_memory(page.address, page.size as u32)
        .is_err()
    {
      return create_error_result(ExecutionStatus::MemoryError, gas_limit);
    }
  }

  // Set initial register values
  let registers = slice::from_raw_parts(initial_registers, 13);
  for (i, &value) in registers.iter().enumerate() {
    if let Some(reg) = Reg::from_raw(i as u32) {
      instance.set_reg(reg, value);
    }
  }

  // Initialize execution state
  instance.set_next_program_counter(ProgramCounter(0));
  instance.set_gas(gas_limit as i64);

  let mut current_pc = ProgramCounter(0);
  let mut segfault_address = 0;

  // Main execution loop
  let status = loop {
    match instance.run() {
      Ok(interrupt) => match interrupt {
        InterruptKind::Finished => break ExecutionStatus::Success,
        InterruptKind::Trap => break ExecutionStatus::Trap,
        InterruptKind::NotEnoughGas => break ExecutionStatus::OutOfGas,
        InterruptKind::Segfault(sfault) => {
          segfault_address = sfault.page_address;
          break ExecutionStatus::Segfault;
        }
        InterruptKind::Step => {
          current_pc = instance.program_counter().unwrap_or(ProgramCounter(0));
          continue;
        }
        InterruptKind::Ecalli(_) => (), // Ignored
      },
      Err(error) => {
        eprintln!("PolkaVM execution error: {}", error);
        return create_error_result(
          ExecutionStatus::InstanceRunError,
          gas_limit,
        );
      }
    }
  };

  // Collect final memory state
  let mut result_pages = Vec::with_capacity(page_count);
  for page in pages {
    if let Ok(mut page_data) =
      instance.read_memory(page.address, page.size as u32)
    {
      let result_page = MemoryPage {
        address: page.address,
        data: page_data.as_mut_ptr(),
        size: page.size,
        is_writable: page.is_writable,
      };
      mem::forget(page_data); // Prevent deallocation
      result_pages.push(result_page);
    }
  }

  let pages_ptr = result_pages.as_mut_ptr();
  let page_count = result_pages.len();
  mem::forget(result_pages); // Prevent deallocation

  // Collect final register values
  let mut registers = [0u64; 13];
  for i in 0..13 {
    if let Some(reg) = Reg::from_raw(i as u32) {
      registers[i] = instance.reg(reg);
    }
  }

  ExecutionResult {
    status,
    final_pc: instance.program_counter().unwrap_or(ProgramCounter(0)).0,
    pages: pages_ptr,
    page_count,
    registers,
    gas_remaining: instance.gas(),
    segfault_address,
  }
}

/// Frees memory allocated during execution
///
/// # Safety
///
/// This function is unsafe because it:
/// - Deallocates memory based on raw pointers
/// - Must be called exactly once for each ExecutionResult
/// - Must not be called with an ExecutionResult that has already been freed
#[no_mangle]
pub unsafe extern "C" fn free_execution_result(result: ExecutionResult) {
  if !result.pages.is_null() {
    let pages = slice::from_raw_parts_mut(result.pages, result.page_count);
    for page in pages {
      Vec::from_raw_parts(page.data, page.size, page.size);
    }
    Vec::from_raw_parts(result.pages, result.page_count, result.page_count);
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use polkavm_common::program::asm;
  use polkavm_common::writer::ProgramBlobBuilder;

  fn create_test_program() -> Vec<u8> {
    let mut builder = ProgramBlobBuilder::new();
    builder.set_rw_data_size(4096);
    builder.add_export_by_basic_block(0, b"main");
    builder.set_code(
      &[
        asm::store_imm_u32(0x20000, 0x12345678), // Store value at memory address
        asm::load_imm(Reg::T0, 0xdeadbeef), // Load test value into register
        asm::ret(),
      ],
      &[],
    );
    builder.into_vec()
  }

  #[test]
  fn test_pvm_execution() {
    let program = create_test_program();
    let mut memory = vec![0u8; 4096];

    let page = MemoryPage {
      address: 0x20000,
      data: memory.as_mut_ptr(),
      size: 4096,
      is_writable: true,
    };

    let registers = [0u64; 13];

    let result = unsafe {
      execute_pvm(
        program.as_ptr(),
        program.len(),
        &page,
        1,
        registers.as_ptr(),
        10000,
      )
    };

    assert_eq!(
      result.status,
      ExecutionStatus::Trap,
      "Execution should succeed"
    );

    unsafe {
      let pages = slice::from_raw_parts(result.pages, result.page_count);
      let first_page = &pages[0];
      let data = slice::from_raw_parts(first_page.data, 4);
      assert_eq!(u32::from_le_bytes(data.try_into().unwrap()), 0x12345678);
      assert_eq!(
        result.registers[2], 0xdeadbeef,
        "Register A0 should contain 0xdeadbeef"
      );

      free_execution_result(result);
    }

    mem::forget(memory); // Prevent double-free
  }

  #[test]
  fn test_invalid_program() {
    let invalid_program = vec![0, 1, 2, 3]; // Invalid PVM bytecode
    let mut memory = vec![0u8; 0x4000];

    let page = MemoryPage {
      address: 0x4000,
      data: memory.as_mut_ptr(),
      size: 0x4000,
      is_writable: true,
    };

    let registers = [0u64; 13];

    let result = unsafe {
      execute_pvm(
        invalid_program.as_ptr(),
        invalid_program.len(),
        &page,
        1,
        registers.as_ptr(),
        10000,
      )
    };

    assert_eq!(
      result.status,
      ExecutionStatus::ProgramError,
      "Should fail with invalid program"
    );
    mem::forget(memory);
  }
}
