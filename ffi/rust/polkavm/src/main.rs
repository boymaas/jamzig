fn main() {
  println!("Hello, world!");
}

#[cfg(test)]
mod tests {
  use polkavm::{
    BackendKind, Engine, InterruptKind, Module, ModuleConfig, ProgramCounter,
    ProgramParts,
  };
  use polkavm::{MemoryMapBuilder, ProgramBlob};
  use polkavm_common::program::Reg::*;
  use polkavm_common::program::asm;
  use polkavm_common::writer::ProgramBlobBuilder;

  fn basic_test_blob() -> ProgramBlob {
    let memory_map = MemoryMapBuilder::new(0x4000)
      .rw_data_size(0x4000)
      .build()
      .unwrap();
    let mut builder = ProgramBlobBuilder::new();
    builder.set_rw_data_size(0x4000);
    builder.add_export_by_basic_block(0, b"main");
    builder.add_import(b"hostcall");
    builder.set_code(
      &[
        asm::store_imm_u32(memory_map.rw_data_address(), 0x12345678),
        asm::add_32(S0, A0, A1),
        asm::ecalli(0),
        asm::add_32(A0, A0, S0),
        asm::ret(),
      ],
      &[],
    );
    ProgramBlob::parse(builder.into_vec().into()).unwrap()
  }

  #[test]
  fn test_raw() {
    // Inspired by polkavm/spectool/src/main.rs
    let mut config = polkavm::Config::new();
    config.set_backend(Some(BackendKind::Interpreter));
    config.set_allow_dynamic_paging(true);

    let engine = Engine::new(&config).unwrap();

    // let raw_bytes = vec![b'P', b'V', b'M', b'\0', 0, 10, 12, 0, 0, 0, 0, 0, 0];
    // let parts = ProgramParts::from_bytes(raw_bytes.into()).unwrap();
    // let blob = ProgramBlob::from_parts(parts.clone()).unwrap();

    let blob = basic_test_blob();

    let mut module_config = ModuleConfig::default();
    module_config.set_strict(true);
    module_config.set_gas_metering(Some(polkavm::GasMeteringKind::Sync));
    module_config.set_step_tracing(true);
    module_config.set_dynamic_paging(true);

    let module =
      Module::from_blob(&engine, &module_config, blob.clone()).unwrap();
    let mut instance = module.instantiate().unwrap();

    // NOTE setting up memory
    // let mut initial_page_map = Vec::new();
    // let mut initial_memory = Vec::new();

    // if module.memory_map().ro_data_size() > 0 {
    //     initial_page_map.push(Page {
    //         address: module.memory_map().ro_data_address(),
    //         length: module.memory_map().ro_data_size(),
    //         is_writable: false,
    //     });
    //
    //     initial_memory.extend(extract_chunks(
    //         module.memory_map().ro_data_address(),
    //         blob.ro_data(),
    //     ));
    // }
    //
    // if module.memory_map().rw_data_size() > 0 {
    //     initial_page_map.push(Page {
    //         address: module.memory_map().rw_data_address(),
    //         length: module.memory_map().rw_data_size(),
    //         is_writable: true,
    //     });
    //
    //     initial_memory.extend(extract_chunks(
    //         module.memory_map().rw_data_address(),
    //         blob.rw_data(),
    //     ));
    // }
    //
    // if module.memory_map().stack_size() > 0 {
    //     initial_page_map.push(Page {
    //         address: module.memory_map().stack_address_low(),
    //         length: module.memory_map().stack_size(),
    //         is_writable: true,
    //     });
    // }
    //
    //
    instance.set_gas(10000);
    instance.set_next_program_counter(ProgramCounter(0));

    // for (reg, value) in Reg::ALL.into_iter().zip(initial_regs) {
    //     instance.set_reg(reg, value);
    // }
    //
    //
    // if module_config.dynamic_paging() {
    //     for page in &initial_page_map {
    //         instance.zero_memory(page.address, page.length).unwrap();
    //         if !page.is_writable {
    //             instance.protect_memory(page.address, page.length).unwrap();
    //         }
    //     }
    //
    //     for chunk in &initial_memory {
    //         instance.write_memory(chunk.address, &chunk.contents).unwrap();
    //     }
    // }
    //
    let mut final_pc = ProgramCounter(0);
    let (final_status, page_fault_address) = loop {
      match instance.run().unwrap() {
        InterruptKind::Finished => break ("halt", None),
        InterruptKind::Trap => break ("panic", None),
        InterruptKind::Ecalli(..) => todo!(),
        InterruptKind::NotEnoughGas => break ("out-of-gas", None),
        InterruptKind::Segfault(segfault) => {
          break ("page-fault", Some(segfault.page_address));
        }
        InterruptKind::Step => {
          final_pc = instance.program_counter().unwrap();
          continue;
        }
      }
    };

    println!("Final status: {}", final_status);
    println!("Final PC: {}", final_pc.0);
    if let Some(addr) = page_fault_address {
      println!("Page fault address: 0x{:x}", addr);
    }
  }
}
