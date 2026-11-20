import Foundation
import KikimimiCore

/// リサーチで、利用者が書いた URL の Web ページを 1 つ読む。
///
/// 送る物は URL と、決まったヘッダ (User-Agent・Accept・Accept-Language を決まった値で) だけ。
/// 会話の中身・設定・ファイルの名前などは、何も送らない。クッキー・資格情報・キャッシュを使わない (毎回まっさらな接続)。
/// GET だけ。待ちは 15 秒。転送は 5 回までで、転送の先にも毎回 `ChatURLs.isAllowed` を当てる。
/// 受け取るのは 200 で、HTML・XHTML・ふつうの文だけ。2 MB で、受け取りながら打ち切る。
///
/// 分かっている穴: 公開の名前が、DNS で内の住所 (127.0.0.1・192.168.x.x など) を指す場合は防げない
/// (名前を引いた後の住所は、URLSession の中で決まり、ここからは見えない)。
/// また、macOS が自分で足すヘッダ (Accept-Encoding・Connection など) は止められない
final class ChatWebFetcher: ChatPageFetching {
    /// 受け取る大きさの上限 (バイト)
    static let maxBytes = 2 * 1024 * 1024
    /// 転送の回数の上限
    static let maxRedirects = 5
    /// 待ちの秒
    static let timeout: TimeInterval = 15

    enum FetchError: LocalizedError, Equatable {
        case notAllowed
        case redirectNotAllowed
        case tooManyRedirects
        case status(Int)
        case unsupportedType(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notAllowed:
                return L("Only public https pages can be read.")
            case .redirectNotAllowed:
                return L("The page moved to an address that cannot be read.")
            case .tooManyRedirects:
                return L("The page moved too many times.")
            case .status(let code):
                return L("The server answered with code %d.", code)
            case .unsupportedType(let type):
                return L("This is not a web page (%@).", type)
            case .network(let message):
                return message
            }
        }
    }

    func fetch(_ url: URL) async throws -> ChatWebPage {
        guard ChatURLs.isAllowed(url) else { throw FetchError.notAllowed }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.waitsForConnectivity = false
        let delegate = FetchDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, text/plain", forHTTPHeaderField: "Accept")
        // 決まった値にする (書かないと、macOS がこの Mac の言語を入れて送る)
        request.setValue("*", forHTTPHeaderField: "Accept-Language")

        let result = try await delegate.run(session.dataTask(with: request))
        let text: String
        if result.mimeType == "text/plain" {
            text = result.decoded
        } else {
            let extracted = WebPageText.extract(html: result.decoded)
            return ChatWebPage(url: result.finalURL ?? url, title: extracted.title, text: extracted.text)
        }
        return ChatWebPage(url: result.finalURL ?? url, title: "", text: text)
    }

    /// `Kikimimi/<版>`
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Kikimimi/" + version
    }

    /// 受け取った物
    struct Fetched {
        let finalURL: URL?
        let mimeType: String
        let decoded: String
    }

    /// 1 回の読み込みの受け口 (URLSession のスレッドで呼ばれる。中の値は lock で守る)
    private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Fetched, Error>?
        private var data = Data()
        private var redirects = 0
        private var failure: FetchError?
        private var response: HTTPURLResponse?
        private var truncated = false

        func run(_ task: URLSessionDataTask) async throws -> Fetched {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Fetched, Error>) in
                    lock.lock()
                    continuation = cont
                    lock.unlock()
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            lock.lock()
            redirects += 1
            let tooMany = redirects > ChatWebFetcher.maxRedirects
            let allowed = request.url.map(ChatURLs.isAllowed) ?? false
            if tooMany { failure = .tooManyRedirects } else if !allowed { failure = .redirectNotAllowed }
            lock.unlock()
            guard !tooMany, allowed else {
                completionHandler(nil)
                task.cancel()
                return
            }
            // 転送の先でも GET だけ (本文は送らない)
            var next = request
            next.httpMethod = "GET"
            next.httpBody = nil
            next.httpShouldHandleCookies = false
            completionHandler(next)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // サーバーの証明書の確かめは、ふつうの扱い。それ以外 (パスワードを求める物など) には答えない
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            // 転送を止めた後の応答 (3xx) は、止めた理由のまま終える
            guard failure == nil else {
                completionHandler(.cancel)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                failure = .network(L("The page could not be read."))
                completionHandler(.cancel)
                return
            }
            guard http.statusCode == 200 else {
                failure = .status(http.statusCode)
                completionHandler(.cancel)
                return
            }
            let type = (http.mimeType ?? "").lowercased()
            guard ["text/html", "application/xhtml+xml", "text/plain"].contains(type) else {
                failure = .unsupportedType(type.isEmpty ? "?" : type)
                completionHandler(.cancel)
                return
            }
            self.response = http
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let room = ChatWebFetcher.maxBytes - self.data.count
            if data.count >= room {
                // 上限まで受け取ったら、そこで止める (全部を貯めてから切らない)
                self.data.append(data.prefix(max(room, 0)))
                truncated = true
                lock.unlock()
                dataTask.cancel()
                return
            }
            self.data.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let cont = continuation
            continuation = nil
            let failure = self.failure
            let response = self.response
            let truncated = self.truncated
            let body = self.data
            lock.unlock()
            guard let cont else { return }
            if let failure {
                cont.resume(throwing: failure)
                return
            }
            // 上限で止めた時の「取り消し」は、失敗ではない
            if let error, !truncated {
                cont.resume(throwing: FetchError.network(error.localizedDescription))
                return
            }
            guard let response else {
                cont.resume(throwing: FetchError.network(L("The page could not be read.")))
                return
            }
            cont.resume(returning: Fetched(finalURL: response.url, mimeType: (response.mimeType ?? "").lowercased(),
                                           decoded: Self.decode(body, encodingName: response.textEncodingName)))
        }

        /// 文字コードは、応答の指定 → 無ければ UTF-8。読めない時は、読めない所を置き換えて UTF-8 で読む
        static func decode(_ data: Data, encodingName: String?) -> String {
            if let name = encodingName {
                let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                if cf != kCFStringEncodingInvalidId {
                    let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                    if let text = String(data: data, encoding: encoding) { return text }
                }
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
