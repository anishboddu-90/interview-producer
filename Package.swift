// swift-tools-version: 5.10
import PackageDescription
let package = Package(name:"InterviewProducer", platforms:[.macOS("15.0")], dependencies:[.package(path:"Vendor/CSpeexDSP")], targets:[
    .systemLibrary(name:"CSQLite",path:"Sources/CSQLite"),
    .executableTarget(name:"InterviewProducer",dependencies:["CSQLite",.product(name:"CSpeexDSP",package:"CSpeexDSP")])])
