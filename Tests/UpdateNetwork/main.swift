import Foundation

let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "updates/config.json"))) as! [String: String]
let key = Data(base64Encoded: config["policyPublicKey"]!)!
var complete = false
var valid = false
let request = UpdatePolicyRequest(url: URL(string: config["policyURL"]!)!) { data in
    if let data, let policy = try? UpdatePolicy.decode(data, publicKey: key, now: Date()) {
        valid = true
        print("Live policy rules: \(policy.rules.count)")
    }
    complete = true
}
let deadline = Date().addingTimeInterval(15)
while !complete && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
precondition(complete && valid, "Live policy endpoint unavailable or policy invalid")
print("PASS: production network client fetched and verified the live policy")
