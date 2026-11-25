import Foundation
import Testing
@testable import FluxCore

struct ContentRangeTests {
    @Test func parsesKnownTotal() {
        #expect(ContentRange.parse("bytes 0-99/1000") == ContentRange(start: 0, end: 99, total: 1000))
    }

    @Test func parsesUnknownTotal() {
        #expect(ContentRange.parse("bytes 10-19/*") == ContentRange(start: 10, end: 19, total: nil))
    }

    @Test(arguments: ["bytes */1000", "items 0-1/2", "bytes 9-1/10", "bytes 0-10/5", "bytes -1-5/10", "bytes 0-1"])
    func rejectsMalformed(_ header: String) {
        #expect(ContentRange.parse(header) == nil)
    }
}

struct FileNamingTests {
    @Test func contentDispositionQuoted() {
        #expect(FileNaming.fileName(fromContentDisposition: #"attachment; filename="report final.pdf""#) == "report final.pdf")
    }

    @Test func contentDispositionToken() {
        #expect(FileNaming.fileName(fromContentDisposition: "attachment; filename=data.csv") == "data.csv")
    }

    @Test func contentDispositionExtendedWins() {
        let header = #"attachment; filename="fallback.txt"; filename*=UTF-8''%E2%82%AC%20rates.txt"#
        #expect(FileNaming.fileName(fromContentDisposition: header) == "€ rates.txt")
    }

    @Test func contentDispositionWithoutName() {
        #expect(FileNaming.fileName(fromContentDisposition: "inline") == nil)
    }

    @Test func nameFromURL() {
        #expect(FileNaming.fileName(from: URL(string: "https://example.com/files/My%20Movie.mkv?x=1")!) == "My Movie.mkv")
        #expect(FileNaming.fileName(from: URL(string: "https://example.com/")!) == "example.com download")
    }

    @Test func extensionFromMimeType() {
        #expect(FileNaming.ensureExtension("download.php", mimeType: "application/zip") == "download.zip")
        #expect(FileNaming.ensureExtension("file", mimeType: "application/pdf") == "file.pdf")
        #expect(FileNaming.ensureExtension("movie.mp4", mimeType: "application/zip") == "movie.mp4")
        #expect(FileNaming.ensureExtension("get", mimeType: "application/octet-stream") == "get")
    }
}

struct PathSafetyTests {
    @Test(arguments: [
        ("../../etc/passwd", "-..-etc-passwd"),
        ("/etc/passwd", "-etc-passwd"),
        (".hidden", "hidden"),
        ("...", "download"),
        ("  \n ", "download"),
        ("a\u{0}b\u{7}c.txt", "abc.txt"),
        ("x:y.txt", "x-y.txt"),
    ])
    func sanitizeProducesSingleSafeComponent(_ input: String, _ expected: String) {
        let cleaned = FileNaming.sanitize(input)
        #expect(cleaned == expected)
        #expect(!cleaned.contains("/"))
        let dir = URL(fileURLWithPath: "/tmp/flux-dl")
        #expect(dir.appendingPathComponent(cleaned).deletingLastPathComponent().path == dir.path)
    }

    @Test func sanitizeCapsLengthKeepingExtension() {
        let cleaned = FileNaming.sanitize(String(repeating: "x", count: 400) + ".zip")
        #expect(cleaned.utf8.count <= 240)
        #expect(cleaned.hasSuffix(".zip"))
    }

    @Test func uniqueNamesNeverReuseExistingFiles() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.zip", "/tmp/x/a (1).zip", "/tmp/x/b"]
        let exists: (URL) -> Bool = { taken.contains($0.path) }
        #expect(FileNaming.uniqueURL(for: "a.zip", in: dir, exists: exists).lastPathComponent == "a (2).zip")
        #expect(FileNaming.uniqueURL(for: "b", in: dir, exists: exists).lastPathComponent == "b (1)")
        #expect(FileNaming.uniqueURL(for: "c.txt", in: dir, exists: exists).lastPathComponent == "c.txt")
    }

    @Test func onlyHTTPLinksAreDownloadable() {
        #expect(LinkExtractor.isDownloadable(URL(string: "https://example.com/a")!))
        #expect(LinkExtractor.isDownloadable(URL(string: "HTTP://example.com/a")!))
        #expect(!LinkExtractor.isDownloadable(URL(string: "file:///etc/passwd")!))
        #expect(!LinkExtractor.isDownloadable(URL(string: "ftp://example.com/a")!))
        #expect(!LinkExtractor.isDownloadable(URL(string: "https:///nohost")!))
    }

    @Test func extractsLinksInOrderWithoutDuplicates() {
        let text = """
        grab https://a.example.com/one.zip and http://b.example.com/two.iso
        again https://a.example.com/one.zip, ignore mailto:x@y.z and ftp://c.example.com/f
        """
        #expect(LinkExtractor.urls(in: text).map(\.absoluteString) == [
            "https://a.example.com/one.zip", "http://b.example.com/two.iso",
        ])
    }
}

struct SegmenterTests {
    @Test func splitsLargestRemainingInHalf() {
        var segs = [Segment(start: 0, end: 999, received: 200)]
        #expect(Segmenter.splitLargest(&segs, minPieceSize: 100) == 1)
        #expect(segs == [Segment(start: 0, end: 599, received: 200), Segment(start: 600, end: 999)])
    }

    @Test func repeatedSplitsTileTheFile() {
        let total: Int64 = 10_000_000
        var segs = [Segment(start: 0, end: total - 1)]
        while segs.count < 16, Segmenter.splitLargest(&segs, minPieceSize: 100_000) != nil {}
        #expect(segs.count == 16)
        for i in segs.indices { segs[i].received = segs[i].end - segs[i].start + 1 }
        #expect(Segmenter.coversExactly(segs, total: total))
    }

    @Test func refusesTinySplits() {
        var segs = [Segment(start: 0, end: 150)]
        #expect(Segmenter.splitLargest(&segs, minPieceSize: 100) == nil)
    }

    @Test func ignoresOpenEndedAndCompleteSegments() {
        var segs = [Segment(start: 0, end: .max), Segment(start: 0, end: 9, received: 10)]
        #expect(Segmenter.splitLargest(&segs, minPieceSize: 1) == nil)
    }

    @Test func coverageRejectsGapsOverlapsAndIncompletePieces() {
        let done = { (s: Int64, e: Int64) in Segment(start: s, end: e, received: e - s + 1) }
        #expect(Segmenter.coversExactly([done(0, 49), done(50, 99)], total: 100))
        #expect(!Segmenter.coversExactly([done(0, 49), done(51, 99)], total: 100), "gap")
        #expect(!Segmenter.coversExactly([done(0, 60), done(50, 99)], total: 100), "overlap")
        #expect(!Segmenter.coversExactly([done(0, 49)], total: 100), "short")
        #expect(!Segmenter.coversExactly([done(0, 49), Segment(start: 50, end: 99, received: 10)], total: 100), "incomplete")
        #expect(Segmenter.coversExactly([Segment(start: 0, end: -1)], total: 0), "empty file")
    }
}
