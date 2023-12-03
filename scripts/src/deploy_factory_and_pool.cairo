use sncast_std::{
    declare, deploy, invoke, call, DeclareResult, DeployResult, InvokeResult, CallResult
};
use starknet::{ ContractAddress, ClassHash };
use debug::PrintTrait;
use deploy_scripts::utils::{owner};

fn main() {
    let max_fee = 9999999999999999;
    let salt = 0x6;

    let pool_declare_result = declare('JediSwapV2Pool', Option::Some(max_fee));
    let pool_class_hash = pool_declare_result.class_hash;

    let factory_declare_result = declare('JediSwapV2Factory', Option::Some(max_fee));
    let factory_class_hash = factory_declare_result.class_hash;
    
    let mut factory_constructor_data = Default::default();
    Serde::serialize(@owner(), ref factory_constructor_data);
    Serde::serialize(@pool_class_hash, ref factory_constructor_data);
    let factory_deploy_result = deploy(factory_class_hash, factory_constructor_data, Option::Some(salt), true, Option::Some(max_fee));
    let factory_contract_address = factory_deploy_result.contract_address;
    
    'Deployed to '.print();
    factory_contract_address.print();


    let token0: ContractAddress = 1.try_into().unwrap();
    let token1: ContractAddress = 2.try_into().unwrap();
    let fee: u32 = 500;

    let mut invoke_data = Default::default();
    Serde::serialize(@token0, ref invoke_data);
    Serde::serialize(@token1, ref invoke_data);
    Serde::serialize(@fee, ref invoke_data);

    let invoke_result = invoke(
        factory_contract_address, 'create_pool', invoke_data, Option::Some(max_fee)
    );
    
    // let deployed_pool_address = invoke_result.data.at(0);
    
    'Invoke tx hash is'.print();
    invoke_result.transaction_hash.print();

    let mut call_data = Default::default();
    Serde::serialize(@token0, ref call_data);
    Serde::serialize(@token1, ref call_data);
    Serde::serialize(@fee, ref call_data);

    let call_result = call(factory_contract_address, 'get_pool', call_data);
    'Call result '.print();
    call_result.data.len().print();
    assert(*call_result.data.at(0) != 0, *call_result.data.at(0));
}