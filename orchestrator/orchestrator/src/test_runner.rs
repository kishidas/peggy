//! Test runner is a testing script for the Peggy Cosmos module. It is built in Rust rather than python or bash
//! to maximize code and tooling shared with the validator-daemon and relayer binaries.

#[macro_use]
extern crate log;

pub mod main_loop;
pub mod tests;
pub mod valset_relaying;

use actix::Arbiter;
use clarity::Address as EthAddress;
use clarity::PrivateKey as EthPrivateKey;
use contact::client::Contact;
use cosmos_peggy::send::send_valset_request;
use cosmos_peggy::send::update_peggy_eth_address;
use cosmos_peggy::utils::wait_for_cosmos_online;
use deep_space::coin::Coin;
use deep_space::private_key::PrivateKey as CosmosPrivateKey;
use ethereum_peggy::utils::get_valset_nonce;
use main_loop::orchestrator_main_loop;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::process::Command;
use std::time::Duration;
use tokio::time::delay_for;

const TIMEOUT: Duration = Duration::from_secs(30);

/// Ethereum keys are generated for every validator inside
/// of this testing application and submitted to the blockchain
/// use the 'update eth address' message.
fn generate_eth_private_key() -> EthPrivateKey {
    let key_buf: [u8; 32] = rand::random();
    EthPrivateKey::from_slice(&key_buf).unwrap()
}

/// Validator private keys are generated via the cosmoscli key add
/// command, from there they are used to create gentx's and start the
/// chain, these keys change every time the container is restarted.
/// The mnemonic phrases are dumped into a text file /validator-phrases
/// the phrases are in increasing order, so validator 1 is the first key
/// and so on. While validators may later fail to start it is guaranteed
/// that we have one key for each validator in this file.
fn parse_validator_keys() -> Vec<CosmosPrivateKey> {
    let filename = "/validator-phrases";
    let file = File::open(filename).expect("Failed to find phrases");
    let reader = BufReader::new(file);
    let mut ret = Vec::new();

    for line in reader.lines() {
        let phrase = line.expect("Error reading phrase file!");
        if phrase.is_empty()
            || phrase.contains("write this mnemonic phrase")
            || phrase.contains("recover your account if")
        {
            continue;
        }
        let key = CosmosPrivateKey::from_phrase(&phrase, "").expect("Bad phrase!");
        ret.push(key);
    }
    ret
}

fn get_keys() -> Vec<(CosmosPrivateKey, EthPrivateKey)> {
    let cosmos_keys = parse_validator_keys();
    let mut ret = Vec::new();
    for c_key in cosmos_keys {
        ret.push((c_key, generate_eth_private_key()))
    }
    ret
}

#[actix_rt::main]
async fn main() {
    env_logger::init();
    info!("Staring Peggy test-runner");
    const COSMOS_NODE: &str = "http://localhost:1317";
    const ETH_NODE: &str = "http://localhost:8545";
    const PEGGY_ID: &str = "foo";
    // this key is the private key for the public key defined in tests/assets/ETHGenesis.json
    // where the full node / miner sends its rewards. Therefore it's always going
    // to have a lot of ETH to pay for things like contract deployments
    let miner_private_key: EthPrivateKey =
        "0xb1bab011e03a9862664706fc3bbaa1b16651528e5f0e7fbfcbfdd8be302a13e7"
            .parse()
            .unwrap();
    let miner_address = miner_private_key.to_public_key().unwrap();

    let contact = Contact::new(COSMOS_NODE, TIMEOUT);
    let web30 = web30::client::Web3::new(ETH_NODE, TIMEOUT);
    let keys = get_keys();
    let test_token_name = "footoken".to_string();

    let fee = Coin {
        denom: test_token_name.clone(),
        amount: 1u32.into(),
    };

    info!("Waiting for Cosmos chain to come online");
    wait_for_cosmos_online(&contact).await;

    // register all validator eth addresses, currently validators can just not do this
    // a full production version of Peggy would refuse to allow validators to enter the pool
    // without registering their address. It would also allow them to delegate their Cosmos addr
    //
    // Either way, validators need to setup their eth addresses out of band and it's not
    // the orchestrators job. So this isn't exactly where it needs to be in the final version
    // but neither is it really that different.
    for (c_key, e_key) in keys.iter() {
        info!(
            "Signing and submitting Eth address {} for validator {}",
            e_key.to_public_key().unwrap(),
            c_key.to_public_key().unwrap().to_address(),
        );
        update_peggy_eth_address(&contact, *e_key, *c_key, fee.clone(), None, None, None)
            .await
            .expect("Failed to update Eth address");
    }

    // wait for the orchestrators to finish registering their eth addresses
    let output = Command::new("npx")
        .args(&[
            "ts-node",
            "/peggy/solidity/contract-deployer.ts",
            &format!("--cosmos-node={}", COSMOS_NODE),
            &format!("--eth-node={}", ETH_NODE),
            &format!("--eth-privkey={:#x}", miner_private_key),
            &format!("--peggy-id={}", PEGGY_ID),
            "--contract=/peggy/solidity/artifacts/Peggy.json",
            "--erc20-contract=/peggy/solidity/artifacts/TestERC20.json",
            "--test-mode=true",
        ])
        .current_dir("/peggy/solidity/")
        .output()
        .expect("Failed to deploy contracts!");
    info!("stdout: {}", String::from_utf8_lossy(&output.stdout));
    info!("stderr: {}", String::from_utf8_lossy(&output.stderr));

    let mut maybe_peggy_address = None;
    let mut maybe_contract_address = None;
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        if line.contains("Peggy deployed at Address -") {
            let address_string = line.split('-').last().unwrap();
            maybe_peggy_address = Some(address_string.trim().parse().unwrap());
        } else if line.contains("ERC20 deployed at Address -") {
            let address_string = line.split('-').last().unwrap();
            maybe_contract_address = Some(address_string.trim().parse().unwrap());
        }
    }
    let peggy_address: EthAddress = maybe_peggy_address.unwrap();
    let contract_address: EthAddress = maybe_contract_address.unwrap();

    // before we start the orchestrators send them some funds so they can pay
    // for things
    for (_c_key, e_key) in keys.iter() {
        let validator_eth_address = e_key.to_public_key().unwrap();

        let balance = web30.eth_get_balance(miner_address).await.unwrap();
        info!(
            "Sending orchestrator 1 eth to pay for fees miner has {} WEI",
            balance
        );
        // send every orchestrator 1 eth to pay for fees
        let txid = web30
            .send_transaction(
                validator_eth_address,
                Vec::new(),
                1_000_000_000_000_000_000u128.into(),
                miner_address,
                miner_private_key,
                vec![],
            )
            .await
            .expect("Failed to send Eth to validator {}");
        web30
            .wait_for_transaction(txid, TIMEOUT, None)
            .await
            .unwrap();
    }

    // start orchestrators, send them some eth so that they can pay for things
    for (c_key, e_key) in keys.iter() {
        info!("Spawning Orchestrator");
        // we have only one actual futures executor thread (see the actix runtime tag on our main function)
        // but that will execute all the orchestrators in our test in parallel
        Arbiter::spawn(orchestrator_main_loop(
            *c_key,
            *e_key,
            web30.clone(),
            contact.clone(),
            peggy_address,
            test_token_name.clone(),
            TIMEOUT,
        ));
    }

    let starting_eth_valset_nonce = get_valset_nonce(peggy_address, miner_address, &web30)
        .await
        .expect("Failed to get starting eth valset");

    // now we send a valset request that the orchestrators will pick up on
    // in this case we send it as the first validator because they can pay the fee
    info!("Sending in valset request");
    send_valset_request(&contact, keys[0].0, fee, None, None, None)
        .await
        .expect("Failed to send valset request");

    let mut current_eth_valset_nonce = get_valset_nonce(peggy_address, miner_address, &web30)
        .await
        .expect("Failed to get current eth valset");
    info!(
        "Our starting valset is {}, waiting for orchestrators to update it",
        current_eth_valset_nonce,
    );
    while starting_eth_valset_nonce == current_eth_valset_nonce {
        info!("Validator set is not yet updated, waiting");
        current_eth_valset_nonce = get_valset_nonce(peggy_address, miner_address, &web30)
            .await
            .expect("Failed to get current eth valset");
        delay_for(Duration::from_secs(10)).await;
    }

    info!("Validator set successfully updated!");

    // TODO verify that a valset update has been performed
    // TODO verify that some transactions have passed etc etc
}
