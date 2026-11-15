import XCTest
@testable import NotchIslandCore

final class PortalTests: XCTestCase {
    func testSanitizeStripsFoldersAndHiddenDots() {
        XCTAssertEqual(PortalFiles.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(PortalFiles.sanitize("..\\evil.txt"), "evil.txt")
        XCTAssertEqual(PortalFiles.sanitize(".hidden"), "hidden")
        XCTAssertEqual(PortalFiles.sanitize("Фото%20моря.heic"), "Фото моря.heic")
        XCTAssertTrue(PortalFiles.sanitize("").hasPrefix("Portal "))
        XCTAssertTrue(PortalFiles.sanitize("..").hasPrefix("Portal "))
    }

    func testSanitizeKeepsExtensionWhenCutting() {
        let long = String(repeating: "а", count: 300) + ".jpg"
        let name = PortalFiles.sanitize(long)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertTrue(name.hasSuffix(".jpg"))
    }

    func testUniqueDestinationCountsUp() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/IMG.jpg", "/tmp/x/IMG 2.jpg"]
        let url = PortalFiles.uniqueDestination(for: "IMG.jpg", in: folder) { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "IMG 3.jpg")
        XCTAssertEqual(PortalFiles.uniqueDestination(for: "notes", in: folder) { $0.lastPathComponent == "notes" }.lastPathComponent, "notes 2")
    }

    func testToken() {
        let t = PortalToken.generate()
        XCTAssertEqual(t.count, 16)
        XCTAssertTrue(PortalToken.matches(t, t))
        XCTAssertFalse(PortalToken.matches(t + "x", t))
        XCTAssertFalse(PortalToken.matches(nil, t))
        XCTAssertFalse(PortalToken.matches("", ""))
    }

    private func run(_ chunks: [String]) -> (HTTPRequestHead?, Data, Bool) {
        let parser = HTTPUploadParser()
        var head: HTTPRequestHead?, body = Data(), done = false
        for chunk in chunks {
            for event in parser.feed(Data(chunk.utf8)) {
                switch event {
                case .head(let h): head = h
                case .body(let d): body.append(d)
                case .done: done = true
                case .failed(let why): XCTFail(why)
                }
            }
        }
        return (head, body, done)
    }

    func testContentLengthBodyInPieces() {
        let (head, body, done) = run(["POST /upload?token=abc HTTP/1.1\r\nHost: x\r\nX-Filename: %D0%A4.txt\r\nContent-Le",
                                      "ngth: 11\r\n\r\nhello", " world"])
        XCTAssertEqual(head?.path, "/upload")
        XCTAssertEqual(head?.token, "abc")
        XCTAssertEqual(head?.fileName, "Ф.txt")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello world")
        XCTAssertTrue(done)
    }

    func testChunkedBody() {
        let (head, body, done) = run(["POST /upload HTTP/1.1\r\nAuthorization: Bearer t1\r\nTransfer-Encoding: chunked\r\n\r\n",
                                      "5\r\nhello\r\n6\r\n", " world\r\n0\r\n\r\n"])
        XCTAssertEqual(head?.token, "t1")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello world")
        XCTAssertTrue(done)
    }

    func testBodyUntilClose() {
        let parser = HTTPUploadParser()
        _ = parser.feed(Data("POST /upload HTTP/1.0\r\n\r\nabc".utf8))
        XCTAssertEqual(parser.finishInput(), [.done])
    }

    func testExpectContinueAndHeaderToken() {
        let (head, _, _) = run(["POST /upload HTTP/1.1\r\nExpect: 100-continue\r\nX-Portal-Token: zz\r\nContent-Length: 0\r\n\r\n"])
        XCTAssertEqual(head?.expectsContinue, true)
        XCTAssertEqual(head?.token, "zz")
    }

    func testMultipartFilePart() {
        let body = Data(("--XYZ\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhi\r\n" +
                         "--XYZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"; filename*=UTF-8''%D0%BC%D0%BE%D1%80%D0%B5.jpg\r\n" +
                         "Content-Type: image/jpeg\r\n\r\nPIXELS\r\n--XYZ--\r\n").utf8)
        let part = Multipart.filePart(in: body, boundary: "XYZ")
        XCTAssertEqual(part?.fileName, "море.jpg")
        XCTAssertEqual(part?.contentType, "image/jpeg")
        XCTAssertEqual(part.map { String(decoding: body[$0.range], as: UTF8.self) }, "PIXELS")
    }

    func testMultipartBoundaryFromHeader() {
        let head = HTTPRequestHead(method: "POST", path: "/upload", query: [:],
                                   headers: ["content-type": "multipart/form-data; boundary=\"abc\""])
        XCTAssertEqual(head.multipartBoundary, "abc")
    }
}
