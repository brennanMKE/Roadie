import Foundation
import Testing

@testable import SkinMuseum

@Suite struct MuseumSkinTests {
    private func skin(_ filename: String) -> MuseumSkin {
        let url = URL(string: "https://example.org/x")!
        return MuseumSkin(md5: String(repeating: "a", count: 32), filename: filename, screenshotURL: url, downloadURL: url, museumURL: url, nsfw: nil)
    }

    @Test func displayNameStripsMuseumIDAndExtension() {
        #expect(skin("ZeldaXtreme_[S130283].wsz").displayName == "ZeldaXtreme")
        #expect(skin("109babe[1]_[S116345].wsz").displayName == "109babe[1]")
        #expect(skin("Plain.wsz").displayName == "Plain")
        #expect(skin("NoExtension").displayName == "NoExtension")
        #expect(skin("Mid_[S1]_name.wsz").displayName == "Mid_[S1]_name")
    }

    @Test func invalidMD5IsRejected() {
        #expect(MuseumSkin.isValidMD5("1f8214678f97b888dfab7c251c943225"))
        #expect(!MuseumSkin.isValidMD5("1F8214678F97B888DFAB7C251C943225"))
        #expect(!MuseumSkin.isValidMD5("1f8214678f97b888dfab7c251c94322"))
        #expect(!MuseumSkin.isValidMD5("../8214678f97b888dfab7c251c943225"))
        #expect(!MuseumSkin.isValidMD5(""))
        #expect(!skin("x.wsz").with(md5: "nothex").isAcceptable)
    }
}

extension MuseumSkin {
    fileprivate func with(md5: String) -> MuseumSkin {
        var copy = self
        copy.md5 = md5
        return copy
    }
}
