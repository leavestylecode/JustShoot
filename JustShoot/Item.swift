//
//  Item.swift
//  JustShoot
//
//  Created by LeaveStyle on 6/8/2025.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
