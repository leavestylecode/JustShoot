import CoreImage

/// Retain the SDR film grade as the primary image for both HDR sources.
enum FilmHDRHighlights {
    /// Evaluate in the RAW renderer's linear Rec.2020 working space.
    static func applying(to grade: CIImage, source: CIImage) -> CIImage? {
        guard grade.extent == source.extent else { return nil }
        return FilmImageKernels.shared[.hdrHighlights]?.apply(extent: grade.extent, arguments: [grade, source])
    }

    @available(iOS 18.0, *)
    static func applyingNativeGainMap(from data: Data, to grade: CIImage,
                                     orientedSourceExtent: CGRect, exifOrientation: Int32) -> CIImage? {
        guard !orientedSourceExtent.isEmpty, orientedSourceExtent.contains(grade.extent),
              let map = CIImage(data: data, options: [.auxiliaryHDRGainMap: true, .applyOrientationProperty: false]),
              !map.extent.isEmpty, !map.extent.isInfinite
        else { return nil }

        let oriented = map.oriented(forExifOrientation: exifOrientation)
        // Map the same crop into the lower-resolution native gain map.
        let scaleX = oriented.extent.width / orientedSourceExtent.width
        let scaleY = oriented.extent.height / orientedSourceExtent.height
        let crop = CGRect(
            x: oriented.extent.minX + (grade.extent.minX - orientedSourceExtent.minX) * scaleX,
            y: oriented.extent.minY + (grade.extent.minY - orientedSourceExtent.minY) * scaleY,
            width: grade.extent.width * scaleX, height: grade.extent.height * scaleY)
        let hdr = grade.applyingGainMap(oriented.cropped(to: crop))
        return hdr.contentHeadroom > 1 && hdr.extent == grade.extent ? hdr : nil
    }
}
