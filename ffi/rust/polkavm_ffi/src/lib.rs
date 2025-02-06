use std::mem;
use std::ptr;
use std::slice;
use std::sync::Once;

use polkavm::RawInstance;
use polkavm::{
  BackendKind, Config, Engine, GasMeteringKind, InterruptKind, Module,
  ModuleConfig, ProgramBlob, ProgramCounter, Reg,
};

static INIT: Once = Once::new();

#[repr(C)]
#[derive(Debug, Clone)]
pub struct MemoryPage {
  address: u32,
  data: *mut u8,
  size: usize,
  is_writable: bool,
}

#[repr(C)]
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum InitializationError {
  EngineError = 1,
  ProgramError = 2,
  ModuleError = 3,
  InstantiationError = 4,
  MemoryError = 5,
}

#[repr(C)]
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum ExecutionStatus {
  Success = 0,
  Trap = 1,
  OutOfGas = 2,
  Segfault = 3,
  InstanceRunError = 4,
  Running = 5,
}

#[repr(C)]
#[derive(Debug)]
pub struct ExecutionResult {
  status: ExecutionStatus,
  final_pc: u32,
  pages: *mut MemoryPage,
  page_count: usize,
  registers: [u64; 13],
  gas_remaining: i64,
  segfault_address: u32,
}

pub struct ProgramExecutor {
  instance: RawInstance,
  initial_pages: Vec<MemoryPage>,
  current_status: ExecutionStatus,
  segfault_address: u32,
}

impl ProgramExecutor {
  /// Creates a new program executor from bytecode and initial state
  ///
  /// # Safety
  ///
  /// This function is unsafe because it:
  /// - Accepts raw pointers as input
  /// - Performs raw memory operations
  pub unsafe fn new(
    bytecode: *const u8,
    bytecode_len: usize,
    initial_pages: *const MemoryPage,
    page_count: usize,
    initial_registers: *const u64,
    gas_limit: u64,
  ) -> Result<Self, InitializationError> {
    // Initialize engine configuration
    let mut config = Config::new();
    config.set_backend(Some(BackendKind::Interpreter));
    config.set_allow_dynamic_paging(true);

    // Initialize engine
    let engine =
      Engine::new(&config).map_err(|_| InitializationError::EngineError)?;

    // Parse program blob
    let raw_bytes = slice::from_raw_parts(bytecode, bytecode_len);
    let blob = ProgramBlob::parse(raw_bytes.to_vec().into())
      .map_err(|_| InitializationError::ProgramError)?;

    // Configure and create module
    let mut module_config = ModuleConfig::default();
    module_config.set_strict(true);
    module_config.set_gas_metering(Some(GasMeteringKind::Sync));
    module_config.set_dynamic_paging(true);
    module_config.set_step_tracing(true);

    let module = Module::from_blob(&engine, &module_config, blob)
      .map_err(|_| InitializationError::ModuleError)?;

    // Instantiate module
    let mut instance = module
      .instantiate()
      .map_err(|_| InitializationError::InstantiationError)?;

    // Store initial pages for later use
    let pages = slice::from_raw_parts(initial_pages, page_count);
    let initial_pages = pages.to_vec();

    // Initialize memory pages
    for page in pages {
      let page_data = slice::from_raw_parts(page.data, page.size);
      instance
        .write_memory(page.address, page_data)
        .map_err(|_| InitializationError::MemoryError)?;

      if !page.is_writable {
        instance
          .protect_memory(page.address, page.size as u32)
          .map_err(|_| InitializationError::MemoryError)?;
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

    Ok(Self {
      instance,
      initial_pages,
      current_status: ExecutionStatus::Running,
      segfault_address: 0,
    })
  }

  /// Executes a single step of the program
  pub fn step(&mut self) -> ExecutionResult {
    match self.instance.run() {
      Ok(interrupt) => {
        self.current_status = match interrupt {
          InterruptKind::Finished => ExecutionStatus::Success,
          InterruptKind::Trap => ExecutionStatus::Trap,
          InterruptKind::NotEnoughGas => ExecutionStatus::OutOfGas,
          InterruptKind::Segfault(sfault) => {
            self.segfault_address = sfault.page_address;
            ExecutionStatus::Segfault
          }
          InterruptKind::Step => ExecutionStatus::Running,
          InterruptKind::Ecalli(_) => ExecutionStatus::Running,
        };
      }
      Err(_) => {
        self.current_status = ExecutionStatus::InstanceRunError;
      }
    }

    self.create_execution_result()
  }

  /// Returns true if the program has finished executing
  pub fn is_finished(&self) -> bool {
    matches!(
      self.current_status,
      ExecutionStatus::Success
        | ExecutionStatus::Trap
        | ExecutionStatus::OutOfGas
        | ExecutionStatus::Segfault
        | ExecutionStatus::InstanceRunError
    )
  }

  /// Creates an execution result from the current state
  fn create_execution_result(&self) -> ExecutionResult {
    // Collect final memory state
    let mut result_pages = Vec::with_capacity(self.initial_pages.len());
    for page in &self.initial_pages {
      if let Ok(mut page_data) =
        self.instance.read_memory(page.address, page.size as u32)
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

    // Collect register values
    let mut registers = [0u64; 13];
    for i in 0..13 {
      if let Some(reg) = Reg::from_raw(i as u32) {
        registers[i] = self.instance.reg(reg);
      }
    }

    ExecutionResult {
      status: self.current_status,
      final_pc: self
        .instance
        .program_counter()
        .unwrap_or(ProgramCounter(0))
        .0,
      pages: pages_ptr,
      page_count,
      registers,
      gas_remaining: self.instance.gas(),
      segfault_address: self.segfault_address,
    }
  }
}

/// Initializes the logging system
#[no_mangle]
pub extern "C" fn init_logging() {
  INIT.call_once(|| {
    env_logger::init();
  });
}

/// Creates a new program executor
///
/// # Safety
///
/// This function is unsafe because it accepts raw pointers as input
#[no_mangle]
pub unsafe extern "C" fn create_executor(
  bytecode: *const u8,
  bytecode_len: usize,
  initial_pages: *const MemoryPage,
  page_count: usize,
  initial_registers: *const u64,
  gas_limit: u64,
) -> *mut ProgramExecutor {
  match ProgramExecutor::new(
    bytecode,
    bytecode_len,
    initial_pages,
    page_count,
    initial_registers,
    gas_limit,
  ) {
    Ok(executor) => Box::into_raw(Box::new(executor)),
    Err(_) => ptr::null_mut(),
  }
}

/// Executes a single step of the program
///
/// # Safety
///
/// This function is unsafe because it:
/// - Accepts a raw pointer as input
/// - Returns unmanaged memory that must be freed
#[no_mangle]
pub unsafe extern "C" fn step_executor(
  executor: *mut ProgramExecutor,
) -> ExecutionResult {
  (&mut *executor).step()
}

/// Checks if the program has finished executing
///
/// # Safety
///
/// This function is unsafe because it accepts a raw pointer as input
#[no_mangle]
pub unsafe extern "C" fn is_executor_finished(
  executor: *const ProgramExecutor,
) -> bool {
  (&*executor).is_finished()
}

/// Frees an executor and its resources
///
/// # Safety
///
/// This function is unsafe because it:
/// - Deallocates memory based on raw pointers
/// - Must be called exactly once for each created executor
#[no_mangle]
pub unsafe extern "C" fn free_executor(executor: *mut ProgramExecutor) {
  if !executor.is_null() {
    drop(Box::from_raw(executor));
  }
}

/// Frees memory allocated during execution
///
/// # Safety
///
/// This function is unsafe because it:
/// - Deallocates memory based on raw pointers
/// - Must be called exactly once for each ExecutionResult
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
        asm::store_imm_u32(0x20000, 0x12345678),
        asm::load_imm(Reg::T0, 0xdeadbeef),
        asm::ret(),
      ],
      &[],
    );
    builder.into_vec()
  }

  #[test]
  fn test_step_execution() {
    let program = create_test_program();
    let mut memory = vec![0u8; 4096];

    let page = MemoryPage {
      address: 0x20000,
      data: memory.as_mut_ptr(),
      size: 4096,
      is_writable: true,
    };

    let registers = [0u64; 13];

    unsafe {
      let mut executor = ProgramExecutor::new(
        program.as_ptr(),
        program.len(),
        &page,
        1,
        registers.as_ptr(),
        10000,
      )
      .expect("Failed to create executor");

      let mut last_result = ExecutionResult {
        status: ExecutionStatus::Running,
        final_pc: 0,
        pages: ptr::null_mut(),
        page_count: 0,
        registers: [0; 13],
        gas_remaining: 0,
        segfault_address: 0,
      };

      while !executor.is_finished() {
        last_result = executor.step();
      }

      assert_eq!(last_result.status, ExecutionStatus::Trap);

      let pages =
        slice::from_raw_parts(last_result.pages, last_result.page_count);
      let first_page = &pages[0];
      let data = slice::from_raw_parts(first_page.data, 4);
      assert_eq!(u32::from_le_bytes(data.try_into().unwrap()), 0x12345678);
      assert_eq!(last_result.registers[2], 0xdeadbeef);

      free_execution_result(last_result);
    }

    mem::forget(memory);
  }
}
