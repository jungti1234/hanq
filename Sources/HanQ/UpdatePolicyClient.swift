import Foundation

/// A bounded, uncached request. Never used from the event-tap callback.
final class UpdatePolicyRequest: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var bytes = Data()
    private let limit: Int
    private var completion: ((Data?) -> Void)?

    init(url: URL, head: Bool = false, completion: @escaping (Data?) -> Void) {
        limit = head ? 0 : 128 * 1024
        self.completion = completion
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = head ? "HEAD" : "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        session.dataTask(with: request).resume()
    }

    func cancel() { finish(nil) }

    private func finish(_ result: Data?) {
        // Delegate callbacks and cancel may race; deliver completion exactly once on main.
        DispatchQueue.main.async { [self] in
            guard let completion else { return }
            self.completion = nil
            session?.invalidateAndCancel()
            session = nil
            completion(result)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https",
              limit == 0 || response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(nil); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - bytes.count else { finish(nil); return }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil ? bytes : nil)
    }
}

final class UpdatePolicyClient {
    private let url: URL
    private let key: Data
    typealias Fetch = (URL, Bool, @escaping (Data?) -> Void) -> UpdatePolicyRequest?
    private let fetch: Fetch
    private let context: UpdatePolicy.Context
    private var request: UpdatePolicyRequest?
    private var generation = 0
    private(set) var isChecking = false
    var onChange: ((UpdatePolicy.Rule?) -> Void)?
    var onCheckingChange: (() -> Void)?
    private var expiryTimer: Timer?

    init(url: URL, key: Data, context: UpdatePolicy.Context,
         fetch: @escaping Fetch = { UpdatePolicyRequest(url: $0, head: $1, completion: $2) }) {
        self.url = url; self.key = key; self.context = context; self.fetch = fetch
    }

    func check(completion: (() -> Void)? = nil) {
        guard !isChecking else { return }
        isChecking = true
        onCheckingChange?()
        generation += 1
        let token = generation
        request = fetch(url, false) { [weak self] data in
            guard let self, token == self.generation else { return }
            let now = Date()
            guard let data, let policy = try? UpdatePolicy.decode(data, publicKey: self.key, now: now),
                  let rule = policy.requiredUpdate(for: self.context, now: now) else {
                self.finish(nil, expires: nil, completion: completion); return
            }
            // Do not strand users on a policy whose public installation file is unavailable.
            self.request = self.fetch(rule.downloadURL, true) { [weak self] response in
                guard let self, token == self.generation else { return }
                let valid = response != nil && policy.expiresAt > Date()
                self.finish(valid ? rule : nil, expires: valid ? policy.expiresAt : nil, completion: completion)
            }
        }
    }

    private func finish(_ rule: UpdatePolicy.Rule?, expires: Date?, completion: (() -> Void)?) {
        request = nil
        isChecking = false
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let expires {
            let timer = Timer(timeInterval: max(0, expires.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                self?.onChange?(nil)
            }
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        }
        onChange?(rule)
        onCheckingChange?()
        completion?()
    }

    func stop() {
        generation += 1
        request?.cancel(); request = nil
        expiryTimer?.invalidate(); expiryTimer = nil
        isChecking = false
    }
}
