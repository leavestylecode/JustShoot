import Foundation

extension FilmSource {
    static func from(_ customLUT: CustomLUT) -> FilmSource {
        .custom(id: customLUT.id, displayName: customLUT.displayName,
                iso: customLUT.iso, fileName: customLUT.fileName)
    }
}
