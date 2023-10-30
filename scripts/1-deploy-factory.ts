import { ethers } from "hardhat";
import { FEE_TO_ADDRESS } from "./constants";

async function main() {
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    console.log("Deploying Mocha Factory with address:", deployerAddress);

    const Factory = await ethers.getContractFactory("MochaFactory");
    const contract = await Factory.deploy(FEE_TO_ADDRESS);

    await contract.deployed();

    const init_code_hash = await contract.pairCodeHash();

    console.log("Mocha Factory Deployed at", contract.address);
    console.log("Factory init code:", init_code_hash);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });