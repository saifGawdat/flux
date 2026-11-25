import Foundation
import Testing
@testable import FluxCore

/// A stand-in for gallery-dl's `-j` output. The last part of the URL picks the behavior:
/// `unsupported` → "Unsupported URL", `login` → extractor error, anything else → a gallery.
func makeFakeGalleryDL() throws -> URL {
    let dir = try tempDir()
    let script = dir.appendingPathComponent("gallery-dl")
    try #"""
    #!/usr/bin/env python3
    import json, sys
    args = sys.argv[1:]
    url = args[-1]
    key = url.rstrip("/").rsplit("/", 1)[-1]
    if "unsupported" in key:
        print(f"[gallery-dl][error] Unsupported URL '{url}'", file=sys.stderr)
        sys.exit(64)
    if "login" in key:
        print(json.dumps([[-1, {"error": "AuthorizationError", "message": "Login required"}]]))
        sys.exit(16)
    album = {"album": "Summer Trip", "user": "sam"}
    print(json.dumps([
        [2, dict(album, title="Day 1")],
        [3, "https://img.example.com/a.jpg", dict(album, title="Day 1", filename="beach", extension="jpg", width=4000, height=3000, size=2500000)],
        [3, "https://img.example.com/a.jpg", dict(album, filename="beach", extension="jpg")],
        [2, dict(album, title="Day 2")],
        [3, "https://img.example.com/clip.mp4", dict(album, filename="clip", extension="mp4")],
        [3, "ytdl:https://v.example.com/watch/1", dict(album, filename="1", extension="mp4")],
        [3, "text:hello", {}],
    ]))
    """#.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

struct PlaylistProbeTests {
    @Test func readsPlaylistEntries() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP())
        let found = try await MediaProbe.inspect(URL(string: "https://www.youtube.com/playlist?list=PLfake")!, tools: tools)
        #expect(found.video == nil)
        let playlist = try #require(found.playlist)
        #expect(playlist.title == "Fake Playlist")
        #expect(playlist.uploader == "Fake Channel")
        #expect(playlist.entries.map(\.title) == ["First", "[Private video]", "Only an ID", "Private or deleted video"],
                "duplicate video listed once")
        #expect(playlist.entries.map(\.isAvailable) == [true, false, true, false], "untitled YouTube entries are private")
        #expect(playlist.entries[2].url == URL(string: "https://www.youtube.com/watch?v=vid00000003"), "bare IDs become watch links")
        #expect(playlist.entries[0].thumbnailURL?.lastPathComponent == "hq.jpg", "smallest thumbnail at least 320 px wide")
        #expect(playlist.availableEntries.count == 2)
        #expect(!playlist.isTruncated)
    }

    @Test func videoOpenedFromPlaylistOffersBoth() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP())
        let url = URL(string: "https://www.youtube.com/watch?v=vid00000001&list=PLfake")!
        #expect(MediaProbe.isVideoInPlaylist(url))
        let found = try await MediaProbe.inspect(url, tools: tools)
        #expect(found.video?.title == "Fake Video: Part 1")
        #expect(found.playlist?.title == "Fake Playlist")
    }

    @Test func singleVideoIsNotAPlaylist() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP())
        let found = try await MediaProbe.inspect(URL(string: "https://youtu.be/ok")!, tools: tools)
        #expect(found.playlist == nil)
        #expect(found.video?.options.count == MediaFormat.allCases.count)
    }

    @Test func channelPlaylistsAreExpandedOneLevel() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP())
        let found = try await MediaProbe.inspect(URL(string: "https://www.youtube.com/@fake/channel")!, tools: tools)
        let playlist = try #require(found.playlist)
        #expect(playlist.title == "Fake Channel")
        // "Inner" expands to the fake playlist; its "Only an ID" entry is the loose video, kept once.
        #expect(playlist.entries.map(\.title) == ["First", "[Private video]", "Only an ID", "Private or deleted video"])
        #expect(playlist.entries.allSatisfy { !$0.isPlaylist })
    }

    @Test func plainWatchLinkIsNotTreatedAsPlaylist() {
        #expect(!MediaProbe.isVideoInPlaylist(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!))
        #expect(!MediaProbe.isVideoInPlaylist(URL(string: "https://www.youtube.com/playlist?list=PL1")!))
        #expect(!MediaProbe.isVideoInPlaylist(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=")!))
    }
}

struct GalleryProbeTests {
    @Test func listsFilesWithNamesAndSizes() async throws {
        let tools = MediaTools(galleryDL: try makeFakeGalleryDL())
        let gallery = try await GalleryProbe.inspect(URL(string: "https://photos.example.com/album/1")!, tools: tools)
        #expect(gallery.title == "Summer Trip", "the key every directory agrees on, not the per-day title")
        #expect(gallery.source == .gallery)
        #expect(gallery.items.map(\.url.absoluteString) == [
            "https://img.example.com/a.jpg", "https://img.example.com/clip.mp4", "https://v.example.com/watch/1",
        ], "duplicates and non-web links dropped")
        let first = gallery.items[0]
        #expect(first.fileName == "beach.jpg" && first.width == 4000 && first.bytes == 2_500_000 && !first.isVideo)
        #expect(gallery.items[1].isVideo && !gallery.items[1].needsMediaExtractor)
        #expect(gallery.items[2].needsMediaExtractor && gallery.items[2].fileName == nil)
        #expect(gallery.imageCount == 1 && gallery.videoCount == 2)
    }

    @Test func unsupportedAndLoginErrors() async throws {
        let tools = MediaTools(galleryDL: try makeFakeGalleryDL())
        await #expect(throws: GalleryProbe.ProbeError.unsupported) {
            try await GalleryProbe.inspect(URL(string: "https://e.com/unsupported")!, tools: tools)
        }
        do {
            _ = try await GalleryProbe.inspect(URL(string: "https://e.com/login")!, tools: tools)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("signed in"))
        }
        await #expect(throws: GalleryProbe.ProbeError.toolMissing) {
            try await GalleryProbe.inspect(URL(string: "https://e.com/x")!, tools: .none)
        }
    }
}

struct PageImageScannerTests {
    static let page = URL(string: "https://news.example.com/stories/42/")!

    @Test func findsImagesInPageOrder() {
        let html = """
            <html><head>
            <title>Ignored &amp; replaced</title>
            <meta property="og:title" content="Big &quot;Story&quot;">
            <meta property="og:image" content="https://cdn.example.com/share.jpg?w=1200&amp;h=630">
            <base href="https://cdn.example.com/media/">
            </head><body>
            <img src="one.jpg" width="800" height="600" alt="x">
            <IMG SRC='two.png'>
            <img src="placeholder.gif" data-src="lazy.webp">
            <img srcset="s.jpg 480w, l.jpg 1600w, m.jpg 800w" src="s.jpg" width="400" height="300">
            <picture><source type="image/avif" srcset="pic.avif 1x, pic@2x.avif 2x"><source type="video/mp4" srcset="no.mp4"></picture>
            <a href="/full/one-large.jpg"><img src="one.jpg"></a>
            <a href="/about">About</a>
            <img src="logo.svg"><img src="data:image/png;base64,AAAA"><img src="one.jpg#again">
            <img src="pixel.gif" width="1" height="1">
            </body></html>
            """
        let found = PageImageScanner.parse(html, pageURL: Self.page)
        #expect(found.title == #"Big "Story""#)
        #expect(found.source == .page)
        #expect(found.items.map(\.url.absoluteString) == [
            "https://cdn.example.com/share.jpg?w=1200&h=630",
            "https://cdn.example.com/media/one.jpg",
            "https://cdn.example.com/media/two.png",
            "https://cdn.example.com/media/lazy.webp",
            "https://cdn.example.com/media/l.jpg",
            "https://cdn.example.com/media/pixel.gif",
            "https://cdn.example.com/media/pic@2x.avif",
            "https://cdn.example.com/full/one-large.jpg",
        ])
        #expect(found.items[1].width == 800 && found.items[1].height == 600)
        #expect(found.items[4].width == nil, "srcset's largest image is bigger than the display size")
        #expect(found.items.first { $0.url.lastPathComponent == "pixel.gif" }?.isSmall == true)
        #expect(found.items[1].isSmall == false)
    }

    @Test func fallsBackToHostForTitle() {
        let found = PageImageScanner.parse("<img src=a.jpg>", pageURL: URL(string: "https://www.example.com/gallery")!)
        #expect(found.title == "example.com · gallery")
        #expect(found.items.first?.url.absoluteString == "https://www.example.com/a.jpg")
    }

    @Test func srcsetPicksLargest() {
        #expect(PageImageScanner.largestCandidate("a.jpg 1x, b.jpg 3x, c.jpg 2x") == "b.jpg")
        #expect(PageImageScanner.largestCandidate("a.jpg 100w,b.jpg 900w") == "b.jpg")
        #expect(PageImageScanner.largestCandidate("only.jpg") == "only.jpg")
        #expect(PageImageScanner.decodeEntities("a&#47;b&#x2F;c &amp;amp;") == "a/b/c &amp;")
    }

    @Test func scansServedPage() async throws {
        let server = try TestServer()
        try "<html><head><title>Local</title></head><body><img src='pic.jpg'><img src='/x/pic2.png'></body></html>"
            .write(to: server.root.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try server.addFile("blob.zip", size: 1000)
        let found = try await PageImageScanner.scan(server.url("page.html"))
        #expect(found.title == "Local")
        #expect(found.items.map(\.url) == [server.url("pic.jpg"), server.url("x/pic2.png")])
        await #expect(throws: PageImageScanner.ScanError.notAPage) {
            try await PageImageScanner.scan(server.url("blob.zip"))
        }
    }
}

struct LinkInspectorTests {
    @Test func directFilesAreNotInspected() async {
        #expect(!LinkInspector.shouldInspect(URL(string: "https://e.com/a.zip")!))
        #expect(!LinkInspector.shouldInspect(URL(string: "https://e.com/photo.WEBP")!))
        #expect(LinkInspector.shouldInspect(URL(string: "https://e.com/gallery")!))
        let found = await LinkInspector.inspect(URL(string: "https://e.com/a.zip")!, tools: .none)
        #expect(!found.foundAnything && found.problem == nil)
    }

    @Test func videoSitesSkipImageSearch() async throws {
        let tools = MediaTools(ytdlp: try makeFakeYTDLP(), galleryDL: try makeFakeGalleryDL())
        let found = await LinkInspector.inspect(URL(string: "https://www.youtube.com/playlist?list=PLfake")!, tools: tools)
        #expect(found.media?.playlist?.title == "Fake Playlist")
        #expect(found.images == nil)
    }

    @Test func galleriesComeFromGalleryDL() async throws {
        let tools = MediaTools(galleryDL: try makeFakeGalleryDL())
        let found = await LinkInspector.inspect(URL(string: "https://photos.example.com/album/1")!, tools: tools)
        #expect(found.images?.source == .gallery)
        #expect(found.images?.items.count == 3)
    }

    @Test func unknownSitesFallBackToPageScan() async throws {
        let server = try TestServer()
        try "<html><body><img src='pic.jpg'></body></html>"
            .write(to: server.root.appendingPathComponent("unsupported.html"), atomically: true, encoding: .utf8)
        let tools = MediaTools(galleryDL: try makeFakeGalleryDL())
        let found = await LinkInspector.inspect(server.url("unsupported.html"), tools: tools)
        #expect(found.images?.source == .page)
        #expect(found.images?.items.map(\.url) == [server.url("pic.jpg")])
    }

    @Test func loginWallIsExplained() async throws {
        let tools = MediaTools(galleryDL: try makeFakeGalleryDL())
        let found = await LinkInspector.inspect(URL(string: "https://www.instagram.com/p/login")!, tools: tools)
        #expect(!found.foundAnything)
        #expect(found.problem?.contains("signed in") == true)
    }

    @Test func fileBehindAPageLikeLinkIsJustAFile() async throws {
        let server = try TestServer()
        try server.addFile("get", size: 2000)
        let found = await LinkInspector.inspect(server.url("get"), tools: .none)
        #expect(!found.foundAnything)
        #expect(found.problem == nil, "no warning: it downloads as a normal file")
    }

    @Test func pageWithoutAnythingSaysSo() async throws {
        let server = try TestServer()
        try "<html><body>Just text</body></html>".write(
            to: server.root.appendingPathComponent("text.html"), atomically: true, encoding: .utf8)
        let found = await LinkInspector.inspect(server.url("text.html"), tools: .none)
        #expect(!found.foundAnything)
        #expect(found.problem == "No video or images found on this page.")
    }
}

@Suite(.serialized)
struct GroupedDownloadTests {
    @Test func playlistKeepsOrderInListQueueAndDatabase() async throws {
        let out = try tempDir()
        let db = try FluxDatabase(url: out.appendingPathComponent("db.sqlite"))
        try await db.save(FluxSettings(downloadDirectory: out, maxConcurrentDownloads: 1))
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions,
                                                mediaTools: MediaTools(ytdlp: try makeFakeYTDLP()))
        let mirror = await EventMirror(manager)
        let group = DownloadGroup(title: "Fake Playlist", kind: .playlist)
        let folder = out.appendingPathComponent("Fake Playlist", isDirectory: true)
        let requests = (0..<3).map { i in
            DownloadManager.NewDownload(
                url: URL(string: "https://www.youtube.com/watch?v=ok\(i)")!, directory: folder,
                kind: .media, mediaFormat: .mp3, title: "Song \(i + 1)", group: group, groupIndex: i)
        }
        let ids = try await manager.add(requests)

        let listed = await manager.allItems.map(\.id)
        #expect(listed == ids, "playlist order in the list")
        let first = try #require(await manager.item(ids[0])?.record)
        #expect(first.fileName == "Song 1" && first.title == "Song 1", "title shows before yt-dlp starts")
        #expect(first.group == group && first.groupIndex == 0)

        await manager.start()
        try await eventually("all three complete", timeout: 60) { ids.allSatisfy { mirror.status($0) == .completed } }
        #expect(mirror.completed == ids, "downloaded in playlist order")
        #expect(mirror.record(ids[2])?.finalPath?.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)

        let saved = try await db.loadDownloads().sorted(by: DownloadRecord.listOrder)
        #expect(saved.map(\.id) == ids)
        #expect(saved.allSatisfy { $0.group == group && $0.mediaFormat == .mp3 })
        #expect(saved.map(\.groupIndex) == [0, 1, 2])
    }

    @Test func imagesFromAPageSendReferer() async throws {
        let server = try TestServer()
        let data = try server.addFile("photo.jpg", size: 300_000)
        let out = try tempDir()
        let db = try FluxDatabase(url: out.appendingPathComponent("db.sqlite"))
        try await db.save(FluxSettings(downloadDirectory: out))
        let manager = try await DownloadManager(database: db, jobOptions: fastOptions, mediaTools: .none)
        let mirror = await EventMirror(manager)
        await manager.start()
        let group = DownloadGroup(title: "Page", kind: .images)
        let ids = try await manager.add([
            .init(url: server.url("referer/photo.jpg"), fileName: "renamed.jpg", kind: .file,
                  referer: server.url("page.html"), group: group),
            .init(url: server.url("referer/photo.jpg"), kind: .file, group: group, groupIndex: 1),
        ])
        try await eventually("downloads settle") { ids.allSatisfy { [.completed, .failed].contains(mirror.status($0)) } }
        let withReferer = try #require(mirror.record(ids[0]))
        #expect(withReferer.status == .completed, "\(withReferer.errorMessage ?? "")")
        #expect(withReferer.fileName == "renamed.jpg")
        #expect(try sha256(of: withReferer.finalPath) == sha256(data))
        #expect(mirror.status(ids[1]) == .failed, "the test server refuses requests without Referer")
        let saved = try #require(try await db.loadDownloads().first { $0.id == ids[0] })
        #expect(saved.referer == server.url("page.html"))
    }
}

/// Opt-in checks against real sites: `FLUX_LIVE_TESTS=1 ./scripts/test.sh --filter LiveCollectionTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FLUX_LIVE_TESTS"] == "1"))
struct LiveCollectionTests {
    static let playlist = URL(string: "https://www.youtube.com/playlist?list=PLBCF2DAC6FFB574DE")! // Google Search Stories, 13 short videos

    @Test func realPlaylistListing() async throws {
        let tools = MediaTools.discover()
        try #require(tools.ytdlp != nil, "install yt-dlp")
        let found = try await MediaProbe.inspect(Self.playlist, tools: tools)
        let playlist = try #require(found.playlist)
        #expect(playlist.title == "Google Search Stories")
        #expect(playlist.entries.count >= 10)
        #expect(playlist.entries.allSatisfy { Thumbnails.youTube(for: $0.url) != nil }, "every entry is a watch link")
        #expect(playlist.entries.contains { ($0.duration ?? 0) > 0 })
        #expect(playlist.entries.filter { !$0.isAvailable }.allSatisfy { $0.title == "Private or deleted video" })
        #expect(playlist.availableEntries.allSatisfy { !$0.title.hasPrefix("Item ") })
    }

    @Test func realVideoInPlaylistOffersBoth() async throws {
        let tools = MediaTools.discover()
        try #require(tools.ytdlp != nil, "install yt-dlp")
        let url = URL(string: "https://www.youtube.com/watch?v=GvgqDSnpRQM&list=PLBCF2DAC6FFB574DE")!
        let found = try await MediaProbe.inspect(url, tools: tools)
        #expect(found.video?.title.isEmpty == false)
        #expect((found.video?.options.count ?? 0) >= 5)
        #expect(found.playlist?.title == "Google Search Stories")
    }

    @Test func realGallery() async throws {
        let tools = MediaTools.discover()
        try #require(tools.galleryDL != nil, "install gallery-dl")
        let url = URL(string: "https://commons.wikimedia.org/wiki/Category:Pictures_of_the_day_(2024)")!
        let found = await LinkInspector.inspect(url, tools: tools)
        let images = try #require(found.images, "\(found.problem ?? "")")
        #expect(images.source == .gallery)
        #expect(images.items.count > 100)
        #expect(images.items.allSatisfy { $0.fileName != nil && $0.width != nil })
    }

    @Test func realPageScan() async throws {
        let found = try await PageImageScanner.scan(URL(string: "https://en.wikipedia.org/wiki/Cat")!)
        #expect(found.items.count > 10)
        #expect(found.items.contains { $0.url.host() == "upload.wikimedia.org" })
        #expect(found.title.contains("Cat"))
    }
}
