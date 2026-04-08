#!/usr/bin/env swift

import AppKit

let pb = NSPasteboard.general

if CommandLine.arguments.count < 2 {
    print("Usage:")
    print("  imagecopy.swift <image-path>         # push image to clipboard")
    print("  imagecopy.swift -o <output-path>    # save clipboard image to file")
    exit(0)
}

if CommandLine.arguments[1] == "-o" {
    guard CommandLine.arguments.count >= 3 else {
        print("Missing output path")
        exit(1)
    }
    let outPath = CommandLine.arguments[2]
    if let objects = pb.readObjects(forClasses: [NSImage.self], options: nil),
       let img = objects.first as? NSImage,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let data = rep.representation(using: .png, properties: [:]) {
        do {
            try data.write(to: URL(fileURLWithPath: outPath))
        } catch {
            print("Failed to write image: \(error)")
            exit(1)
        }
    } else {
        print("No image in clipboard")
        exit(1)
    }
} else {
    let path = CommandLine.arguments[1]
    let url = URL(fileURLWithPath: path)
    guard let img = NSImage(contentsOf: url) else {
        print("Failed to load image")
        exit(1)
    }
    pb.clearContents()
    pb.writeObjects([img])
}
