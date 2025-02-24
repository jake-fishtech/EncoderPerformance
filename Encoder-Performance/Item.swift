//
//  Item.swift
//  Encoder-Performance
//
//  Created by Jake Fishman on 1/19/25.
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
