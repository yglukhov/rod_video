import json, os, strutils, tables

import rod.tools.rodasset.tree_traversal
import nimPNG

import nimx.pathutils

import webm.writer, webm.webm

let patchComposition = true

proc exportVideoFromComposition*(compPath, nodeName: string) =
    let c = parseFile(compPath)
    let n = c.findNode(nodeName)
    if n.isNil:
        raise newException(Exception, "Node " & nodeName & " not found")

    type Chapter = (string, uint64, uint64)

    var chapters = newSeq[Chapter]()

    template frameToTime(f: int): uint64 = uint64(f) * 33333333

    var keyFrames = newSeq[int]()

    var fps = 0.0
    var anims = 1

    for k, a in c.compositionAnimationsForNodeProperty(nodeName, "curFrame"):
        let values = a["values"]
        let start = values[0].num.int
        let stop = values[^1].num.int

        let duration = a["duration"].getFNum()
        let numFrames = values.len
        fps = (fps + numFrames.float / duration) / anims.float
        inc anims

        keyFrames.add(start)
        chapters.add((k, frameToTime(start), frameToTime(stop)))

    echo "avg fps: ", fps

    let writer = newWriter()

    let componentNode = n.firstComponentOfType("Sprite")
    let frames = componentNode["fileNames"]
    let totalFrames = frames.len

    let videoPath = frames[0].str.changeFileExt("webm")
    let firstFramePath = compPath.parentDir / frames[0].str
    var firstFrame = loadPNG32(firstFramePath)
    let width = firstFrame.width
    let height = firstFrame.height
    firstFrame = nil

    writer.getFrame = proc(frameIdx: int, img: var vpx_image_t, flags: var cint): bool =
        if frameIdx >= totalFrames: return false
        echo "fr: ", frameIdx

        let p = loadPNG32(compPath.parentDir / frames[frameIdx].str)

        assert(p.width == width)
        assert(p.height == height)

        const encodeAlphaToY = true

        for y in 0 ..< height:
            for x in 0 ..< width:
                let rgba = cast[ptr int32](addr p.data[(y * width + x) * 4])[]
                let py = cast[ptr uint8](cast[uint](img.planes[0]) + uint(y * img.stride[0] + x))

                when encodeAlphaToY:
                    let enc = rgbaToYauv(rgba)
                    py[] = enc.ya
                else:
                    let enc = rgbToYuv(rgba)
                    py[] = enc.y

                let pu = cast[ptr uint8](cast[uint](img.planes[1]) + uint((y div 2) * img.stride[1] + (x div 2)))
                pu[] = enc.u
                let pv = cast[ptr uint8](cast[uint](img.planes[2]) + uint((y div 2) * img.stride[2] + (x div 2)))
                pv[] = enc.v

        if frameIdx in keyFrames:
            flags = VPX_EFLAG_FORCE_KF

        result = true

    writer.write(width, height, compPath.parentDir / videoPath, fps, chapters)

    if patchComposition:
        # Delete frame image files:
        for f in frames:
            removeFile(compPath.parentDir / f.str)
        componentNode.delete("fileNames")
        componentNode["_c"] = %"VideoComponent"
        componentNode["fileName"] = %videoPath

        let animName = nodeName & ".curFrame"
        for k, a in c["animations"]:
            if animName in a: a.delete(animName)
        writeFile(compPath, $c)

when isMainModule:
    import cligen

    proc extract(nodeName, compPath: string) =
        exportVideoFromComposition(compPath, nodeName)

    dispatchMulti([extract])
