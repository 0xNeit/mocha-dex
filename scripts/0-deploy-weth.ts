import { ethers } from "hardhat";

async function main() {
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    console.log("Deploying WETH with the address:", deployerAddress);

    const weth = await ethers.getContractFactory("WETH");
    const contract = await weth.deploy();

    await contract.deployed();

    console.log("WETH Deployed at", contract.address);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });