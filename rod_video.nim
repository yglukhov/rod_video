import rod / [node, component, viewport, tools/serializer]
import nimx / [context, portable_gl, types, composition, resource, animation]

import math, json

import webm.reader

type VideoComponent* = ref object of Component
    yTex: TextureRef
    uTex: TextureRef
    vTex: TextureRef
    aTex: TextureRef
    webmReader: WebmReader
    animation: Animation
    frameWidth, frameHeight: int
    texWidth, texHeight: int
    framerate: float
    lastFrameTime: float

var videoComposition = newComposition """
uniform sampler2D uYTex;
uniform sampler2D uUTex;
uniform sampler2D uVTex;

#define A_IN_Y

#ifndef A_IN_Y
uniform sampler2D uATex;
#endif

uniform vec2 uUVk;

void compose() {
    float r,g,b,y,cb,cr,a;
    vec2 v = vPos / bounds.zw;
    v.y = 1.0 - v.y;
    v = v * uUVk;

#ifdef A_IN_Y
    y = texture2D(uYTex, v).r;
    a = floor(y / 0.25) * 4.0;
    y = mod(y, 0.25) * 4.0;
#else
    y = texture2D(uYTex, v).r;
    a = texture2D(uATex, v).r;
#endif

    y = (y - 0.062) * 1.164;
    cb = texture2D(uUTex, v).r;
    cr = texture2D(uVTex, v).r;
    r = y + 1.402 * (cr - 0.5);
    g = y - 0.344 * (cb - 0.5) - 0.714 * (cr - 0.5);
    b = y + 1.772 * (cb - 0.5);

    gl_FragColor = vec4(r, g, b, a);
}
"""

proc newTex(): TextureRef =
    let gl = currentContext().gl
    result = gl.createTexture()
    gl.bindTexture(gl.TEXTURE_2D, result)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    # gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    # gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

proc openVideoFile*(c: VideoComponent, path: string) =
    if not c.webmReader.isNil:
        c.webmReader.close()
    c.webmReader = newReader(path)
    c.framerate = 1 / c.webmReader.fps
    echo "framerate: ", c.framerate

proc nextFrame(c: VideoComponent)

method init*(c: VideoComponent) =
    procCall c.Component.init()

    c.yTex = newTex()
    let gl = currentContext().gl
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)

    c.uTex = newTex()
    c.vTex = newTex()
    c.aTex = newTex()

    c.animation = newAnimation()
    c.animation.onAnimate = proc(p: float) =
        let curT = c.animation.curLoop.float + p
        if c.lastFrameTime + c.framerate <= curT:
            c.lastFrameTime = curT
            c.nextFrame()

method draw*(s: VideoComponent) =
    let c = currentContext()
    let gl = c.gl
    let uvk = newVector2(s.frameWidth / s.texWidth, s.frameHeight / s.texHeight)

    videoComposition.draw(newRect(0, 0, s.frameWidth.Coord, s.frameHeight.Coord)):
        setUniform("uYTex", s.yTex)
        setUniform("uUTex", s.uTex)
        setUniform("uVTex", s.vTex)
        setUniform("uATex", s.aTex)
        setUniform("uUVk", uvk)

method componentNodeWasAddedToSceneView*(c: VideoComponent) =
    c.node.sceneView.addAnimation(c.animation)

method componentNodeWillBeRemovedFromSceneView*(c: VideoComponent) =
    c.node.sceneView.removeAnimation(c.animation)


var tmpBuf = newSeq[uint8](10)

when false:
    proc encode(y, a: float): uint8 =
        let yy = uint8(y * 63)
        let aa = uint8(a * 3)
        result = (aa shl 6) or yy

    template decodeY(c: uint8): uint8 =
        uint8(uint32(c and 0b00111111) * 255 div 63)

    template decodeA(c: uint8): uint8 =
        uint8(uint32(c shr 6) * 255 div 3)

    proc decode(c: uint8): (uint8, uint8) =
        (decodeY(c), decodeA(c))

    proc dataToTmpBufY(data: ptr uint8, stride: int, w, h, tw, th: int) =
        let totalLen = tw * th
        if tmpBuf.len < totalLen:
            tmpBuf.setLen(totalLen)
        for i in 0 ..< h:
            let destRowStart = i * tw
            let destRowEnd = destRowStart + w
            for x in 0 ..< w:
                let b = cast[ptr uint8](cast[csize](data) + cast[csize](i * stride + x))[]
                tmpBuf[destRowStart + x] = decodeY(b)

            # Nullify garbage at the edge of the row
            if destRowEnd + 1 < totalLen:
                tmpBuf[destRowEnd] = 0
                tmpBuf[destRowEnd + 1] = 0

    proc dataToTmpBufA(data: ptr uint8, stride: int, w, h, tw, th: int) =
        let totalLen = tw * th
        if tmpBuf.len < totalLen:
            tmpBuf.setLen(totalLen)
        for i in 0 ..< h:
            let destRowStart = i * tw
            let destRowEnd = destRowStart + w
            for x in 0 ..< w:
                let b = cast[ptr uint8](cast[csize](data) + cast[csize](i * stride + x))[]
                tmpBuf[destRowStart + x] = decodeA(b)

            # Nullify garbage at the edge of the row
            if destRowEnd + 1 < totalLen:
                tmpBuf[destRowEnd] = 0
                tmpBuf[destRowEnd + 1] = 0

    echo decode(encode(0.5, 0.5))
    echo decode(encode(0.1, 0.2))

proc dataToTmpBuf(data: ptr uint8, stride: int, w, h, tw, th: int) =
    let totalLen = tw * th
    if tmpBuf.len < totalLen:
        tmpBuf.setLen(totalLen)
    for i in 0 ..< h:
        let destRowStart = i * tw
        let destRowEnd = destRowStart + w
        copyMem(addr tmpBuf[destRowStart], cast[pointer](cast[csize](data) + cast[csize](i * stride)), w)

        # Nullify garbage at the edge of the row
        if destRowEnd + 1 < totalLen:
            tmpBuf[destRowEnd] = 0
            tmpBuf[destRowEnd + 1] = 0

proc nextDecodedImage(w: WebmReader): ptr vpx_image_t =
    if w.decodeNextFrame():
        result = w.frameImage()

proc nextFrame(c: VideoComponent) =
    if c.webmReader.isNil: return
    var img = c.webmReader.nextDecodedImage()
    if img.isNil:
        c.webmReader.rewind()
        img = c.webmReader.nextDecodedImage()
        assert(not img.isNil)

    let alphaImg = c.webmReader.alphaImage()
    #echo "ts: ", s.webmReader.frameTimestamp()

    let gl = currentContext().gl
    let format = gl.LUMINANCE

    let w = nextPowerOfTwo(img.d_w.int)
    let h = nextPowerOfTwo(img.d_w.int)
    c.texWidth = w
    c.texHeight = h
    c.frameWidth = img.d_w.int
    c.frameHeight = img.d_h.int

    #glPixelStorei(GL_UNPACK_ROW_LENGTH, img.stride[0])
    dataToTmpBuf(img.planes[0], img.stride[0].int, img.d_w.int, img.d_h.int, w, h)
    gl.bindTexture(gl.TEXTURE_2D, c.yTex)
    gl.texImage2D(gl.TEXTURE_2D, 0, format.GLint, GLsizei(w), GLsizei(h), 0, format, gl.UNSIGNED_BYTE, addr tmpBuf[0])

    let w2 = img.d_w.int div 2
    let h2 = img.d_h.int div 2
#    glPixelStorei(GL_UNPACK_ROW_LENGTH, img.stride[1])
    dataToTmpBuf(img.planes[1], img.stride[1].int, w2, h2, w div 2, h div 2)
    gl.bindTexture(gl.TEXTURE_2D, c.uTex)
    gl.texImage2D(gl.TEXTURE_2D, 0, format.GLint, GLsizei(w div 2), GLsizei(h div 2), 0, format, gl.UNSIGNED_BYTE, addr tmpBuf[0])

#    glPixelStorei(GL_UNPACK_ROW_LENGTH, img.stride[2])
    dataToTmpBuf(img.planes[2], img.stride[2].int, w2, h2, w div 2, h div 2)
    gl.bindTexture(gl.TEXTURE_2D, c.vTex)
    gl.texImage2D(gl.TEXTURE_2D, 0, format.GLint, GLsizei(w div 2), GLsizei(h div 2), 0, format, gl.UNSIGNED_BYTE, addr tmpBuf[0])

    if not alphaImg.isNil:
        dataToTmpBuf(alphaImg.planes[0], alphaImg.stride[0].int, alphaImg.d_w.int, alphaImg.d_h.int, w, h)
        gl.bindTexture(gl.TEXTURE_2D, c.aTex)
        gl.texImage2D(gl.TEXTURE_2D, 0, format.GLint, GLsizei(w), GLsizei(h), 0, format, gl.UNSIGNED_BYTE, addr tmpBuf[0])

proc rewindToTime*(c: VideoComponent, t: float) =
    if c.webmReader.isNil: return
    c.webmReader.rewindToTime(t)
    c.nextFrame()

proc rewindToChapter*(c: VideoComponent, name: string) =
    if c.webmReader.isNil: return
    let chapters = c.webmReader.chapters()
    var t: uint64
    for c in chapters:
        if c.name == name:
            t = c.a
    c.webmReader.rewindToNearestKeyframeAtTime(float(t) / 1000000000 + 0.1)

method deserialize*(c: VideoComponent, j: JsonNode, s: Serializer) =
    var v = j["fileName"]
    c.openVideoFile(pathForResource(v.str))

registerComponent(VideoComponent)

when isMainModule:
    import nimx.window
    import nimx.text_field
    import nimx.system_logger # Required because of Nim bug (#4433)
    import nimx.timer
    import nimx.mini_profiler
    import nimx.slider, nimx.button

    import rod.component.camera
    import rod.quaternion

    import random
    import times

    var allVideos = newSeq[VideoComponent]()

    proc makeVideoNode(rn: Node, x, y: float32) =
        let videoNode = rn.newChild("video")
        videoNode.position = newVector3(x, y)
        videoNode.scale = newVector3(0.05, 0.05, 0.05)
        let c = videoNode.component(VideoComponent)
        c.openVideoFile(pathForResource("seahorse.webm"))
        allVideos.add(c)

    proc startApplication() =
        var mainWindow = newWindow(newRect(40, 40, 1200, 600))

        mainWindow.title = "Webm test"

        let vp = SceneView.new(mainWindow.bounds)
        vp.backgroundColor = newColor(1.0, 0, 0, 1)

        sharedProfiler().enabled = true

        vp.autoresizingMask = { afFlexibleWidth, afFlexibleHeight }
        vp.rootNode = newNode("(root)")
        let cameraNode = vp.rootNode.newChild("camera")
        discard cameraNode.component(Camera)
        cameraNode.positionZ = 100

        let r = vp.rootNode

        const coords = [(-50, 0)]#, (-50, -33), (-18, 0), (-18, -33), (15, 0), (15, -33)]

        var rotationVectors = newSeq[float32](coords.len)

        var i = 0
        setInterval(1.0) do():
            if i < coords.len:
                r.makeVideoNode(coords[i][0].float32, coords[i][1].float32)
                rotationVectors[i] = 0 #random(0.5) - 0.25

                if i == 0:
                    let c = allVideos[0]
                    for j, chap in c.webmReader.chapters:
                        let b = Button.new(newRect(Coord(210 + j * 105), 5, 100, 25))
                        closureScope:
                            let name = chap.name
                            b.title = "Chapter: " & name
                            b.onAction do():
                                c.rewindToChapter(name)
                        vp.addSubview(b)

                inc i

        mainWindow.addSubview(vp)

        # setInterval(1 / 30) do():
        #     for i, c in allVideos:
        #         c.nextFrame()
        #         #c.node.rotation = c.node.rotation * aroundZ(rotationVectors[i])
        #     vp.setNeedsDisplay()

        let s = Slider.new(newRect(5, 5, 200, 25))
        vp.addSubview(s)
        s.onAction do():
            for i, c in allVideos:
                let st = epochTime()
                c.rewindToTime(s.value)
                echo "t: ", epochTime() - st


    runApplication:
        startApplication()
