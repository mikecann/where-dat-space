import Foundation
import CoreGraphics

public struct RGB: Sendable {
    public let r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public var cgColor: CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
}
public enum ColorMode: String, CaseIterable, Sendable { case type, folder }
public enum FileCategory: String, CaseIterable, Sendable {
    case video = "Video", images = "Images", audio = "Audio", documents = "Documents"
    case archives = "Archives & disk images", code = "Code & text", apps = "Apps & binaries", other = "Other", small = "Smaller files (mixed)"
    public var color: RGB {
        switch self {
        case .video: RGB(0.66,0.43,0.88)
        case .images: RGB(0.93,0.48,0.64)
        case .audio: RGB(0.95,0.67,0.29)
        case .documents: RGB(0.32,0.65,0.90)
        case .archives: RGB(0.85,0.53,0.29)
        case .code: RGB(0.32,0.75,0.60)
        case .apps: RGB(0.43,0.51,0.87)
        case .other: RGB(0.55,0.63,0.68)
        case .small: RGB(0.47,0.56,0.58)
        }
    }
    public static func classify(_ name: String) -> FileCategory {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4","mov","mkv","webm","avi","m4v","r3d": .video
        case "jpg","jpeg","png","heic","gif","webp","tiff","tif","raw","psd","svg","exr": .images
        case "mp3","wav","flac","aif","aiff","m4a","aac","ogg": .audio
        case "pdf","doc","docx","xls","xlsx","ppt","pptx","pages","numbers","key","epub": .documents
        case "zip","gz","bz2","xz","tar","7z","rar","dmg","iso","sparsebundle","sparseimage": .archives
        case "swift","c","h","cpp","hpp","m","mm","rs","go","js","jsx","ts","tsx","json","py","rb","java","kt","md","txt","yml","yaml","toml","html","css","sh","lock","xml","sql": .code
        case "app","exe","dylib","so","a","o","bin","wasm","class","jar","metallib": .apps
        default: .other
        }
    }
}
public enum FolderColors {
    public static func color(at rank: Int) -> RGB {
        let hue = (Double(rank) * 0.61803398875 + 0.56).truncatingRemainder(dividingBy: 1)
        let h = hue * 6, c = 0.48, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = 0.30
        switch Int(h) {
        case 0: return RGB(c+m,x+m,m)
        case 1: return RGB(x+m,c+m,m)
        case 2: return RGB(m,c+m,x+m)
        case 3: return RGB(m,x+m,c+m)
        case 4: return RGB(x+m,m,c+m)
        default: return RGB(c+m,m,x+m)
        }
    }
}
