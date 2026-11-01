//
//  GarminSmartwatchPlugin.swift
//  GarminSmartwatchPlugin
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import GarminSmartwatchKit
import GarminSmartwatchKitUI
import LoopKitUI

class GarminSmartwatchPlugin: NSObject, SmartwatchManagerUIPlugin {
    public var smartwatchManagerType: SmartwatchManagerUI.Type? {
        GarminSmartwatchManager.self
    }
}
