import { ethers } from "hardhat";
import { FACTORY, WETH } from "./deployments";
import { FEE_TO_ADDRESS } from "./constants";

async function main() {
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    console.log("Deploying Mocha Router with address:", deployerAddress);

    const Router = await ethers.getContractFactory("MochaRouter");
    const contract = await Router.deploy(FACTORY, WETH, FEE_TO_ADDRESS);

    await contract.deployed();

    console.log("Mocha Router Deployed at", contract.address);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });