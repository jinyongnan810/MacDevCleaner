//
//  Item.swift
//  MacDevCleaner
//
//  Created by Yuunan kin on 2026/10/31.
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
