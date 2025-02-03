use polkavm::{
  BackendKind, Engine, InterruptKind, Module, ModuleConfig, ProgramBlob,
  ProgramCounter,
};

#[repr(C)]
pub struct MemoryPage {
  address: u32,
  data: *mut u8,
  size: usize,
  is_writable: bool,
}

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

#[repr(C)]
pub struct ExecutionResult {
  status: ExecutionStatus,
  final_pc: u32,
  pages: *mut MemoryPage,
  page_count: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn execute_pvm(
  bytecode: *const u8,
  bytecode_len: usize,
  initial_pages: *const MemoryPage,
  page_count: usize,
  gas_limit: u64,
) -> ExecutionResult {
  let raw_bytes = unsafe { std::slice::from_raw_parts(bytecode, bytecode_len) };
  let pages = unsafe { std::slice::from_raw_parts(initial_pages, page_count) };

  // Set up engine
  let mut config = polkavm::Config::new();
  config.set_backend(Some(BackendKind::Interpreter));
  config.set_allow_dynamic_paging(true);

  let engine = match Engine::new(&config) {
    Ok(e) => e,
    Err(_) => {
      return ExecutionResult {
        status: ExecutionStatus::EngineError,
        final_pc: 0,
        pages: std::ptr::null_mut(),
        page_count: 0,
      };
    }
  };

  // Parse program
  let blob = match ProgramBlob::parse(raw_bytes.to_vec().into()) {
    Ok(b) => b,
    Err(_) => {
      return ExecutionResult {
        status: ExecutionStatus::ProgramError,
        final_pc: 0,
        pages: std::ptr::null_mut(),
        page_count: 0,
      };
    }
  };

  // Configure module
  let mut module_config = ModuleConfig::default();
  module_config.set_strict(true);
  module_config.set_gas_metering(Some(polkavm::GasMeteringKind::Sync));
  module_config.set_dynamic_paging(true);

  let module = match Module::from_blob(&engine, &module_config, blob) {
    Ok(m) => m,
    Err(_) => {
      return ExecutionResult {
        status: ExecutionStatus::ModuleError,
        final_pc: 0,
        pages: std::ptr::null_mut(),
        page_count: 0,
      };
    }
  };

  let mut instance = match module.instantiate() {
    Ok(i) => i,
    Err(_) => {
      return ExecutionResult {
        status: ExecutionStatus::InstantiationError,
        final_pc: 0,
        pages: std::ptr::null_mut(),
        page_count: 0,
      };
    }
  };

  // Set up memory pages
  for page in pages {
    let page_data = unsafe { std::slice::from_raw_parts(page.data, page.size) };
    if let Err(_) = instance.write_memory(page.address, page_data) {
      return ExecutionResult {
        status: ExecutionStatus::MemoryError,
        final_pc: 0,
        pages: std::ptr::null_mut(),
        page_count: 0,
      };
    }

    if !page.is_writable {
      if let Err(_) = instance.protect_memory(page.address, page.size as u32) {
        return ExecutionResult {
          status: ExecutionStatus::MemoryError,
          final_pc: 0,
          pages: std::ptr::null_mut(),
          page_count: 0,
        };
      }
    }
  }

  // Execute
  instance.set_gas(gas_limit as i64);
  instance.set_next_program_counter(ProgramCounter(0));

  let mut final_pc = ProgramCounter(0);
  let status = loop {
    match instance.run() {
      Ok(interrupt) => match interrupt {
        InterruptKind::Finished => break ExecutionStatus::Success,
        InterruptKind::Trap => break ExecutionStatus::Trap,
        InterruptKind::NotEnoughGas => break ExecutionStatus::OutOfGas,
        InterruptKind::Segfault(_) => break ExecutionStatus::Segfault,
        InterruptKind::Step => {
          final_pc = instance.program_counter().unwrap_or(ProgramCounter(0));
          continue;
        }
        _ => break ExecutionStatus::UnknownError,
      },
      Err(_) => {
        return ExecutionResult {
          status: ExecutionStatus::InstanceRunError,
          final_pc: final_pc.0,
          pages: std::ptr::null_mut(),
          page_count: 0,
        };
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
      std::mem::forget(page_data); // Prevent deallocation
      result_pages.push(result_page);
    }
  }

  let pages_ptr = result_pages.as_mut_ptr();
  let page_count = result_pages.len();
  std::mem::forget(result_pages); // Prevent deallocation

  ExecutionResult {
    status,
    final_pc: final_pc.0,
    pages: pages_ptr,
    page_count,
  }
}

#[unsafe(no_mangle)]
pub extern "C" fn free_execution_result(result: ExecutionResult) {
  unsafe {
    let pages = std::slice::from_raw_parts_mut(result.pages, result.page_count);
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
        asm::ret(),
      ],
      &[],
    );
    builder.into_vec()
  }

  #[test]
  fn test_pvm_execution() {
    let program = create_test_program();

    // Create initial memory page
    let mut memory = vec![0u8; 4096];
    let page = MemoryPage {
      address: 0x20000,
      data: memory.as_mut_ptr(),
      size: 4096,
      is_writable: true,
    };

    let result = execute_pvm(program.as_ptr(), program.len(), &page, 1, 10000);

    assert_eq!(
      result.status,
      ExecutionStatus::Trap,
      "Execution should succeed"
    );

    // Check memory modification
    unsafe {
      let pages = std::slice::from_raw_parts(result.pages, result.page_count);
      let first_page = &pages[0];
      let data = std::slice::from_raw_parts(first_page.data, 4);
      assert_eq!(u32::from_le_bytes(data.try_into().unwrap()), 0x12345678);
    }

    free_execution_result(result);

    std::mem::forget(memory); // Prevent double-free
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

    let result = execute_pvm(
      invalid_program.as_ptr(),
      invalid_program.len(),
      &page,
      1,
      10000,
    );

    assert_eq!(
      result.status,
      ExecutionStatus::ProgramError,
      "Should fail with invalid program"
    );
    std::mem::forget(memory);
  }
}
