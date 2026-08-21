//
//  Attachment.swift
//  FieldForge
//
//  Photos, signatures, business cards, and voice memos. One model rather than
//  four because the storage, the thumbnailing, and the "never lose this"
//  guarantee are identical for all of them.
//

import Foundation
import SwiftData
import UIKit

@Model
final class Attachment {

    var id: UUID = UUID()

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var kindRawValue: String = AttachmentKind.photo.rawValue
    var kind: AttachmentKind {
        get { AttachmentKind(rawValue: kindRawValue) ?? .photo }
        set { kindRawValue = newValue.rawValue }
    }

    /// The bytes. External storage means SwiftData writes these beside the
    /// database rather than inside it, and CloudKit uploads them as assets.
    @Attribute(.externalStorage) var data: Data?

    /// A small JPEG kept inline so scrolling a list of visits never has to
    /// touch the external files.
    var thumbnailData: Data?

    var caption: String = ""

    /// For in-kind item photos: what the donor said it was worth. Labelled as
    /// the donor's estimate wherever it appears.
    var donorEstimatedValueMinorUnits: Int = 0

    var capturedAt: Date = Date.now

    /// True when the image came from the camera at capture time rather than
    /// the photo library. Matters for anything used as location evidence.
    var isCapturedLive: Bool = false

    var latitude: Double?
    var longitude: Double?

    /// Byte count, cached so storage management does not have to load files.
    var byteCount: Int = 0

    /// Transcript, for `.voiceNote` attachments.
    var transcript: String = ""

    var createdAt: Date = Date.now

    // MARK: Relationships — inverses live on the three parents

    var contact: Contact?
    var visit: Visit?
    var gift: Gift?

    init(kind: AttachmentKind = .photo, data: Data? = nil, caption: String = "") {
        self.kindRawValue = kind.rawValue
        self.data = data
        self.caption = caption
        self.byteCount = data?.count ?? 0
    }

    var image: UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
    }

    var thumbnail: UIImage? {
        if let thumbnailData { return UIImage(data: thumbnailData) }
        return image
    }

    var donorEstimatedValue: Money {
        Money(minorUnits: donorEstimatedValueMinorUnits)
    }

    var formattedSize: String {
        Int64(byteCount).formatted(.byteCount(style: .file))
    }

    /// Builds and stores a downscaled preview. Called once, at capture, on a
    /// background task — never during a scroll.
    func generateThumbnail(maxDimension: CGFloat = 240) {
        guard let image, thumbnailData == nil else { return }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        thumbnailData = resized.jpegData(compressionQuality: 0.7)
    }
}
