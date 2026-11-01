import CoreImage

enum FilmMaterialRenderer {
    struct PreparedCube {
        let image: CIImage
        let shape: CIVector

        init(_ lut: CubeLUT) {
            // Avoid a 128²-tall bitmap, which exceeds older renderers' texture
            // limits. Reshape the same ordered nodes; padding is never sampled.
            let width = lut.dimension * 8
            let count = lut.dimension * lut.dimension * lut.dimension
            let height = (count + width - 1) / width
            var data = lut.data
            let padding = (width * height - count) * 16
            if padding > 0 { data.append(Data(count: padding)) }
            image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil).samplingNearest()
            shape = CIVector(x: CGFloat(lut.dimension), y: CGFloat(width), z: CGFloat(height))
        }
    }

    /// Reused by the serial Live Photo filter. Bitmap tables are never rebuilt per frame.
    struct Prepared {
        let material: FilmMaterial
        let input: CIImage
        let tables: [CIImage]
        let inputDimension: Float
        let finishDimension: Float

        init(_ material: FilmMaterial) {
            self.material = material
            input = material.input.image
            tables = [material.density.image, material.print.image, material.finish.image]
            inputDimension = material.input.isIdentity ? 0 : Float(material.input.dimension)
            finishDimension = material.finish.isIdentity ? 0 : Float(material.finish.dimension)
        }
    }
    static func prepare() throws {
        guard inputKernel != nil, finishKernel != nil, compositeKernel != nil else { throw CubeLUT.ParseError.malformed }
    }
    private static let inputKernel = kernel("justShootMaterialInput")
    private static let cubeKernel = kernel("justShootColorCube")
    private static let finishKernel = kernel("justShootMaterialFinish")
    private static let compositeKernel: CIColorKernel? = {
        guard let data = library else { return nil }
        return try? CIColorKernel(functionName: "justShootMaterialComposite", fromMetalLibraryData: data)
    }()
    private static let library: Data? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else { return nil }
        return try? Data(contentsOf: url)
    }()
    private static func kernel(_ name: String) -> CIKernel? {
        guard let data = library else { return nil }
        return try? CIKernel(functionName: name, fromMetalLibraryData: data)
    }

    /// iOS 17's built-in cube filter is limited to 64³. Sample larger frozen
    /// tables directly, preserving every node and the preview's trilinear math.
    static func applyingCube(to image: CIImage, prepared: PreparedCube) -> CIImage? {
        guard let cubeKernel,
              let numeric = image.matchedFromWorkingSpace(to: FilmImagePipeline.colorSpace) else { return nil }
        let table = prepared.image
        return cubeKernel.apply(extent: numeric.extent, roiCallback: { index, rect in
            index == 0 ? rect : table.extent
        }, arguments: [numeric, table, prepared.shape])?
            .matchedToWorkingSpace(from: FilmImagePipeline.colorSpace)
    }

    static func stages(image: CIImage, prepared: Prepared, optics: FilmOpticsParameters,
        grain: FilmGrainParameters, seed: UInt32, cancellation: CaptureRenderCancellation?) -> FilmImagePipeline.Stages? {
        let material = prepared.material
        guard let inputKernel, let finishKernel,
              let numeric = image.matchedFromWorkingSpace(to: FilmImagePipeline.colorSpace) else { return nil }
        let inputTable = prepared.input
        guard let input = inputKernel.apply(extent: numeric.extent, roiCallback: { index, rect in
            index == 0 ? rect : inputTable.extent
        }, arguments: [numeric, inputTable, prepared.inputDimension]) else { return nil }
        var exposed = input
        if optics.hasLightDiffusion {
            guard let highlight = FilmImageKernels.shared[.highlight], let compositeKernel,
                  let energy = highlight.apply(extent: input.extent,
                    arguments: [input, FilmOpticsParameters.highlightThreshold]) else { return nil }
            let longEdge = max(input.extent.width, input.extent.height)
            let halo = energy.applyingGaussianBlur(sigma: CGFloat(optics.radiusPixels(optics.halationRadius, forLongEdge: longEdge) * 0.55)).cropped(to: input.extent)
            let bloom = energy.applyingGaussianBlur(sigma: CGFloat(optics.radiusPixels(optics.bloomRadius, forLongEdge: longEdge) * 0.45)).cropped(to: input.extent)
            guard let combined = compositeKernel.apply(extent: input.extent,
                arguments: [input, halo, bloom, optics.halationAmount, optics.halationHue, optics.bloomAmount]) else { return nil }
            exposed = combined
        }
        guard cancellation?.isCancelled != true else { return nil }
        let tables = prepared.tables
        let amount = grain.renderAmount(forLongEdge: max(input.extent.width, input.extent.height))
        let size = grain.pixelSize(forLongEdge: max(input.extent.width, input.extent.height))
        func developed(_ source: CIImage, amount: Float, headroom: Float) -> CIImage? {
            finishKernel.apply(extent: input.extent, roiCallback: { index, rect in
                index == 0 ? rect : tables[Int(index) - 1].extent
            }, arguments: [source] + tables + [
                CIVector(x: CGFloat(material.density.dimension), y: CGFloat(material.print.dimension), z: CGFloat(prepared.finishDimension)),
                CIVector(x: CGFloat(material.densityMaximum.x), y: CGFloat(material.densityMaximum.y), z: CGFloat(material.densityMaximum.z)),
                CIVector(x: CGFloat(material.refinement.x), y: CGFloat(material.refinement.y), z: CGFloat(material.refinement.z), w: CGFloat(material.refinement.w)),
                CIVector(x: CGFloat(amount), y: CGFloat(size), z: CGFloat(grain.chroma), w: 0), Float(seed & 0x00FF_FFFF),
                CIVector(x: CGFloat(headroom), y: CGFloat(optics.headroomShoulder))
            ])?.matchedToWorkingSpace(from: FilmImagePipeline.colorSpace)
        }
        // Diagnostic branches stay lazy. Ordinary exports evaluate only final.
        guard let final = developed(exposed, amount: amount, headroom: optics.headroomAmount),
              let graded = developed(input, amount: 0, headroom: 0),
              let optical = developed(exposed, amount: 0, headroom: optics.headroomAmount) else { return nil }
        return .init(graded: graded, optical: optical, final: final)
    }
}
