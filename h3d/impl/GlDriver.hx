package h3d.impl;
import h3d.impl.Driver;
import h3d.mat.Pass;

#if (js||cpp)

#if js
import js.html.Uint16Array;
import js.html.Uint8Array;
import js.html.Float32Array;
private typedef GL = js.html.webgl.GL;
private typedef Uniform = js.html.webgl.UniformLocation;
#elseif cpp
import openfl.gl.GL;
private typedef Uint16Array = openfl.utils.Int16Array;
private typedef Uint8Array = openfl.utils.UInt8Array;
private typedef Float32Array = openfl.utils.Float32Array;
#end

private class CompiledShader {
	public var s : js.html.webgl.Shader;
	public var vertex : Bool;
	public var globals : Uniform;
	public var params : Uniform;
	public var textures : Array<Uniform>;
	public function new(s,vertex) {
		this.s = s;
		this.vertex = vertex;
	}
}

private class CompiledProgram {
	public var p : js.html.webgl.Program;
	public var vertex : CompiledShader;
	public var fragment : CompiledShader;
	public var stride : Int;
	public var attribNames : Array<String>;
	public var attribs : Array<{ index : Int, type : Int, size : Int, offset : Int }>;
	public function new() {
	}
}

@:access(h3d.impl.Shader)
class GlDriver extends Driver {

	#if js
	var canvas : js.html.CanvasElement;
	public var gl : js.html.webgl.RenderingContext;
	#elseif cpp
	static var gl = GL;
	var fixMult : Bool;
	#end
	
	var curAttribs : Int;
	var curProgram : CompiledProgram;
	var curMatBits : Int;
	var programs : Map<Int, CompiledProgram>;
	var hasTarget : Bool;
	
	public function new() {
		#if js
		canvas = @:privateAccess hxd.Stage.getCanvas();
		if( canvas == null ) throw "Canvas #webgl not found";
		gl = canvas.getContextWebGL({alpha:false});
		if( gl == null ) throw "Could not acquire GL context";
		// debug if webgl_debug.js is included
		untyped if( __js__('typeof')(WebGLDebugUtils) != "undefined" ) gl = untyped WebGLDebugUtils.makeDebugContext(gl);
		#elseif cpp
		// check for a bug in HxCPP handling of sub buffers
		var tmp = new Float32Array(8);
		var sub = new Float32Array(tmp.buffer, 0, 4);
		fixMult = sub.length == 1; // should be 4
		#end
		programs = new Map();
		curAttribs = 0;
		curMatBits = -1;
		selectMaterialBits(0);
	}
	
	override function reset() {
		gl.useProgram(null);
		curProgram = null;
		hasTarget = false;
	}
	
	override function getShaderInputNames() {
		return curProgram.attribNames;
	}
	
	function compileShader( shader : hxsl.RuntimeShader.RuntimeShaderData ) {
		var type = shader.vertex ? GL.VERTEX_SHADER : GL.FRAGMENT_SHADER;
		var s = gl.createShader(type);
		var code = hxsl.GlslOut.toGlsl(shader.data);
		gl.shaderSource(s, code);
		gl.compileShader(s);
		if( gl.getShaderParameter(s, GL.COMPILE_STATUS) != cast 1 ) {
			var log = gl.getShaderInfoLog(s);
			var line = code.split("\n")[Std.parseInt(log.substr(9)) - 1];
			if( line == null ) line = "" else line = "(" + StringTools.trim(line) + ")";
			throw "An error occurred compiling the shaders: " + log + line;
		}
		return new CompiledShader(s,shader.vertex);
	}
	
	function initShader( p : CompiledProgram, s : CompiledShader, shader : hxsl.RuntimeShader.RuntimeShaderData ) {
		var prefix = s.vertex ? "vertex" : "fragment";
		s.globals = gl.getUniformLocation(p.p, prefix + "Globals");
		s.params = gl.getUniformLocation(p.p, prefix + "Params");
		s.textures = [for( i in 0...shader.textures.length ) gl.getUniformLocation(p.p, prefix + "Textures[" + i + "]")];
	}
	
	override function selectShader( shader : hxsl.RuntimeShader ) {
		var p = programs.get(shader.id);
		if( p == null ) {
			p = new CompiledProgram();
			p.vertex = compileShader(shader.vertex);
			p.fragment = compileShader(shader.fragment);
			p.p = gl.createProgram();
			gl.attachShader(p.p, p.vertex.s);
			gl.attachShader(p.p, p.fragment.s);
			gl.linkProgram(p.p);
			if( gl.getProgramParameter(p.p, GL.LINK_STATUS) != cast 1 ) {
				var log = gl.getProgramInfoLog(p.p);
				throw "Program linkage failure: "+log;
			}
			initShader(p, p.vertex, shader.vertex);
			initShader(p, p.fragment, shader.fragment);
			p.attribNames = [];
			p.attribs = [];
			p.stride = 0;
			for( v in shader.vertex.data.vars )
				switch( v.kind ) {
				case Input:
					var t = GL.FLOAT;
					var size = switch( v.type ) {
					case TVec(n, _): n;
					case TBytes(n): t = GL.BYTE; n;
					case TFloat: 1;
					default: throw "assert " + v.type;
					}
					p.attribs.push( { offset : p.stride, index : gl.getAttribLocation(p.p, v.name), size:size, type:t } );
					p.attribNames.push(v.name);
					p.stride += size;
				default:
				}
			programs.set(shader.id, p);
		}
		if( curProgram == p ) return;
		gl.useProgram(p.p);
		for( i in curAttribs...p.attribs.length ) {
			gl.enableVertexAttribArray(i);
			curAttribs++;
		}
		while( curAttribs > p.attribs.length )
			gl.disableVertexAttribArray(--curAttribs);
		curProgram = p;
	}
	
	override function uploadShaderBuffers( buf : h3d.shader.Buffers, which : h3d.shader.Buffers.BufferKind ) {
		uploadBuffer(curProgram.vertex, buf.vertex, which);
		uploadBuffer(curProgram.fragment, buf.fragment, which);
	}
	
	function uploadBuffer( s : CompiledShader, buf : h3d.shader.Buffers.ShaderBuffers, which : h3d.shader.Buffers.BufferKind ) {
		switch( which ) {
		case Globals:
			if( s.globals != null ) gl.uniform4fv(s.globals, new Float32Array(buf.globals.toData()));
		case Params:
			if( s.params != null ) gl.uniform4fv(s.params, new Float32Array(buf.params.toData()));
		case Textures:
			for( i in 0...s.textures.length ) {
				var t = buf.tex[i];
				gl.activeTexture(GL.TEXTURE0 + i);
				gl.uniform1i(s.textures[i], i);
				
				gl.bindTexture(GL.TEXTURE_2D, t.t.t);
				var flags = TFILTERS[Type.enumIndex(t.mipMap)][Type.enumIndex(t.filter)];
				gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, flags[0]);
				gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, flags[1]);
				var w = TWRAP[Type.enumIndex(t.wrap)];
				gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, w);
				gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, w);
			}
		}
	}
	
	override function selectMaterial( pass : Pass ) {
		selectMaterialBits(@:privateAccess pass.bits);
		// TODO : Blend Op value sync
	}
	
	function selectMaterialBits( bits : Int ) {
		if( hasTarget ) {
			// switch culling font/back
			var c = Pass.getCulling(bits);
			if( c == 1 ) c = 2 else if( c == 2 ) c = 1;
			bits = (bits & ~Pass.culling_mask) | (c << Pass.culling_offset);
		}
		var diff = bits ^ curMatBits;
		if( diff == 0 )
			return;
		if( diff & Pass.culling_mask != 0 ) {
			var cull = Pass.getCulling(bits);
			if( cull == 0 )
				gl.disable(GL.CULL_FACE);
			else {
				if( Pass.getCulling(curMatBits) == 0 ) gl.enable(GL.CULL_FACE);
				gl.cullFace(FACES[cull]);
			}
		}
		if( diff & (Pass.blendSrc_mask | Pass.blendDst_mask | Pass.blendAlphaSrc_mask | Pass.blendAlphaDst_mask) != 0 ) {
			var csrc = Pass.getBlendSrc(bits);
			var cdst = Pass.getBlendDst(bits);
			var asrc = Pass.getBlendAlphaSrc(bits);
			var adst = Pass.getBlendAlphaDst(bits);
			if( csrc == asrc && cdst == adst ) {
				if( csrc == 0 && cdst == 1 )
					gl.disable(GL.BLEND);
				else {
					if( curMatBits < 0 || (Pass.getBlendSrc(curMatBits) == 0 && Pass.getBlendDst(curMatBits) == 1) ) gl.enable(GL.BLEND);
					gl.blendFunc(BLEND[csrc], BLEND[cdst]);
				}
			} else {
				if( curMatBits < 0 || (Pass.getBlendSrc(curMatBits) == 0 && Pass.getBlendDst(curMatBits) == 1) ) gl.enable(GL.BLEND);
				gl.blendFuncSeparate(BLEND[csrc], BLEND[cdst], BLEND[asrc], BLEND[adst]);
			}
		}
		if( diff & (Pass.blendOp_mask | Pass.blendAlphaOp_mask) != 0 ) {
			var cop = Pass.getBlendOp(bits);
			var aop = Pass.getBlendAlphaOp(bits);
			if( cop == aop )
				gl.blendEquation(OP[cop]);
			else
				gl.blendEquationSeparate(OP[cop], OP[aop]);
		}
		if( diff & Pass.depthWrite_mask != 0 )
			gl.depthMask(Pass.getDepthWrite(bits) != 0);
		if( diff & Pass.depthTest_mask != 0 ) {
			var cmp = Pass.getDepthTest(bits);
			if( cmp == 0 )
				gl.disable(GL.DEPTH_TEST);
			else {
				if( curMatBits < 0 || Pass.getDepthTest(curMatBits) == 0 ) gl.enable(GL.DEPTH_TEST);
				gl.depthFunc(COMPARE[cmp]);
			}
		}
		if( diff & Pass.colorMask_mask != 0 ) {
			var m = Pass.getColorMask(bits);
			gl.colorMask(m & 1 != 0, m & 2 != 0, m & 4 != 0, m & 8 != 0);
		}
		curMatBits = bits;
	}
	
	override function clear( r : Float, g : Float, b : Float, a : Float ) {
		gl.clearColor(r, g, b, a);
		gl.clearDepth(1);
		gl.clear(GL.COLOR_BUFFER_BIT|GL.DEPTH_BUFFER_BIT);
	}
	
	override function resize(width, height) {
		#if js
		// prevent infinite grow if pixelRatio != 1
		if( canvas.style.width == "" ) {
			canvas.style.width = Std.int(width / js.Browser.window.devicePixelRatio)+"px";
			canvas.style.height = Std.int(height / js.Browser.window.devicePixelRatio)+"px";
		}
		canvas.width = width;
		canvas.height = height;
		#elseif cpp
		// resize window
		#end
		gl.viewport(0, 0, width, height);
	}
	
	override function allocTexture( t : h3d.mat.Texture ) : Texture {
		var tt = gl.createTexture();
		var tt : Texture = { t : tt, width : t.width, height : t.height };
		gl.bindTexture(GL.TEXTURE_2D, tt.t);
		gl.texImage2D(GL.TEXTURE_2D, 0, GL.RGBA, tt.width, tt.height, 0, GL.RGBA, GL.UNSIGNED_BYTE, null);
		if( t.isTarget ) {
			var fb = gl.createFramebuffer();
			gl.bindFramebuffer(GL.FRAMEBUFFER, fb);
			gl.framebufferTexture2D(GL.FRAMEBUFFER, GL.COLOR_ATTACHMENT0, GL.TEXTURE_2D, tt.t, 0);
			gl.bindFramebuffer(GL.FRAMEBUFFER, null);
			tt.fb = fb;
		}
		gl.bindTexture(GL.TEXTURE_2D, null);
		return tt;
	}
	
	override function allocVertex( count : Int, stride : Int ) : VertexBuffer {
		var b = gl.createBuffer();
		#if js
		gl.bindBuffer(GL.ARRAY_BUFFER, b);
		if( count * stride == 0 ) throw "assert";
		gl.bufferData(GL.ARRAY_BUFFER, count * stride * 4, GL.STATIC_DRAW);
		gl.bindBuffer(GL.ARRAY_BUFFER, null);
		#else
		var tmp = new Uint8Array(count * stride * 4);
		gl.bindBuffer(GL.ARRAY_BUFFER, b);
		gl.bufferData(GL.ARRAY_BUFFER, tmp, GL.STATIC_DRAW);
		gl.bindBuffer(GL.ARRAY_BUFFER, null);
		#end
		return { b : b, stride : stride };
	}
	
	override function allocIndexes( count : Int ) : IndexBuffer {
		var b = gl.createBuffer();
		#if js
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, b);
		gl.bufferData(GL.ELEMENT_ARRAY_BUFFER, count * 2, GL.STATIC_DRAW);
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, null);
		#else
		var tmp = new Uint16Array(count);
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, b);
		gl.bufferData(GL.ELEMENT_ARRAY_BUFFER, tmp, GL.STATIC_DRAW);
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, null);
		#end
		return b;
	}

	override function disposeTexture( t : Texture ) {
		gl.deleteTexture(t.t);
		if( t.rb != null ) gl.deleteRenderbuffer(t.rb);
		if( t.fb != null ) gl.deleteFramebuffer(t.fb);
	}

	override function disposeIndexes( i : IndexBuffer ) {
		gl.deleteBuffer(i);
	}
	
	override function disposeVertex( v : VertexBuffer ) {
		gl.deleteBuffer(v.b);
	}

	override function uploadTextureBitmap( t : h3d.mat.Texture, bmp : hxd.BitmapData, mipLevel : Int, side : Int ) {
		var img = bmp.toNative();
		gl.bindTexture(GL.TEXTURE_2D, t.t.t);
		gl.texImage2D(GL.TEXTURE_2D, mipLevel, GL.RGBA, GL.RGBA, GL.UNSIGNED_BYTE, img.getImageData(0,0,bmp.width,bmp.height));
		gl.bindTexture(GL.TEXTURE_2D, null);
	}

	override function uploadTexturePixels( t : h3d.mat.Texture, pixels : hxd.Pixels, mipLevel : Int, side : Int ) {
		gl.bindTexture(GL.TEXTURE_2D, t.t.t);
		pixels.convert(RGBA);
		var pixels = new Uint8Array(pixels.bytes.getData());
		gl.texImage2D(GL.TEXTURE_2D, mipLevel, GL.RGBA, t.width, t.height, 0, GL.RGBA, GL.UNSIGNED_BYTE, pixels);
		gl.bindTexture(GL.TEXTURE_2D, null);
	}
	
	override function uploadVertexBuffer( v : VertexBuffer, startVertex : Int, vertexCount : Int, buf : hxd.FloatBuffer, bufPos : Int ) {
		var stride : Int = v.stride;
		var buf = new Float32Array(buf.getNative());
		var sub = new Float32Array(buf.buffer, bufPos, vertexCount * stride #if cpp * (fixMult?4:1) #end);
		gl.bindBuffer(GL.ARRAY_BUFFER, v.b);
		gl.bufferSubData(GL.ARRAY_BUFFER, startVertex * stride * 4, sub);
		gl.bindBuffer(GL.ARRAY_BUFFER, null);
	}

	override function uploadVertexBytes( v : VertexBuffer, startVertex : Int, vertexCount : Int, buf : haxe.io.Bytes, bufPos : Int ) {
		var stride : Int = v.stride;
		var buf = new Uint8Array(buf.getData());
		var sub = new Uint8Array(buf.buffer, bufPos, vertexCount * stride * 4);
		gl.bindBuffer(GL.ARRAY_BUFFER, v.b);
		gl.bufferSubData(GL.ARRAY_BUFFER, startVertex * stride * 4, sub);
		gl.bindBuffer(GL.ARRAY_BUFFER, null);
	}

	override function uploadIndexesBuffer( i : IndexBuffer, startIndice : Int, indiceCount : Int, buf : hxd.IndexBuffer, bufPos : Int ) {
		var buf = new Uint16Array(buf.getNative());
		var sub = new Uint16Array(buf.buffer, bufPos, indiceCount #if cpp * (fixMult?2:1) #end);
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, i);
		gl.bufferSubData(GL.ELEMENT_ARRAY_BUFFER, startIndice * 2, sub);
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, null);
	}

	override function uploadIndexesBytes( i : IndexBuffer, startIndice : Int, indiceCount : Int, buf : haxe.io.Bytes , bufPos : Int ) {
		var buf = new Uint8Array(buf.getData());
		var sub = new Uint8Array(buf.buffer, bufPos, indiceCount * 2);
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, i);
		gl.bufferSubData(GL.ELEMENT_ARRAY_BUFFER, startIndice * 2, sub);
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, null);
	}
	
	public function setupTexture( t : h3d.mat.Texture, mipMap : h3d.mat.Data.MipMap, filter : h3d.mat.Data.Filter, wrap : h3d.mat.Data.Wrap ) {
		gl.bindTexture(GL.TEXTURE_2D, t.t.t);
		var flags = TFILTERS[Type.enumIndex(mipMap)][Type.enumIndex(filter)];
		gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, flags[0]);
		gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, flags[1]);
		var w = TWRAP[Type.enumIndex(wrap)];
		gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, w);
		gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, w);
	}
		
	override function selectBuffer( v : VertexBuffer ) {
		var stride : Int = v.stride;
		if( stride < curProgram.stride )
			throw "Buffer stride (" + stride + ") and shader stride (" + curProgram.stride + ") mismatch";
		gl.bindBuffer(GL.ARRAY_BUFFER, v.b);
		for( a in curProgram.attribs )
			gl.vertexAttribPointer(a.index, a.size, a.type, false, stride * 4, a.offset * 4);
	}
	
	override function selectMultiBuffers( buffers : Buffer.BufferOffset ) {
		for( a in curProgram.attribs ) {
			gl.bindBuffer(GL.ARRAY_BUFFER, buffers.b.b.vbuf.b);
			gl.vertexAttribPointer(a.index, a.size, a.type, false, buffers.b.b.stride * 4, buffers.offset * 4);
			buffers = buffers.next;
		}
	}
	
	override function draw( ibuf : IndexBuffer, startIndex : Int, ntriangles : Int ) {
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, ibuf);
		gl.drawElements(GL.TRIANGLES, ntriangles * 3, GL.UNSIGNED_SHORT, startIndex * 2);
		gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, null);
	}
	
	override function present() {
		gl.finish();
	}

	override function isDisposed() {
		return gl.isContextLost();
	}
	
	override function setRenderTarget( tex : h3d.impl.Texture, useDepth : Bool, clearColor : Int ) {
		if( tex == null ) {
			gl.bindFramebuffer(GL.FRAMEBUFFER, null);
			gl.viewport(0, 0, canvas.width, canvas.height);
			hasTarget = false;
			return;
		}
		hasTarget = true;
		gl.bindFramebuffer(GL.FRAMEBUFFER, tex.fb);
		gl.viewport(0, 0, tex.width, tex.height);
		if( useDepth && tex.rb == null ) {
			tex.rb = gl.createRenderbuffer();
			gl.bindRenderbuffer(GL.RENDERBUFFER, tex.rb);
			gl.renderbufferStorage(GL.RENDERBUFFER, GL.DEPTH_COMPONENT16, tex.width, tex.height);
			gl.framebufferRenderbuffer(GL.FRAMEBUFFER, GL.DEPTH_ATTACHMENT, GL.RENDERBUFFER, tex.rb);
			gl.bindRenderbuffer(GL.RENDERBUFFER, null);
		}
		clear(((clearColor >> 16) & 0xFF) / 255, ((clearColor >> 8) & 0xFF) / 255, (clearColor & 0xFF) / 255, (clearColor >>> 24) / 255);
	}

	override function init( onCreate : Bool -> Void, forceSoftware = false ) {
		#if js
		var ready = false;
		// wait until all assets have properly load
		js.Browser.window.addEventListener("load", function(_) {
			if( !ready ) {
				ready = true;
				onCreate(false);
			}
		});
		#else
		haxe.Timer.delay(onCreate.bind(false), 1);
		#end
	}
	
	static var TFILTERS = [
		[[GL.NEAREST,GL.NEAREST],[GL.LINEAR,GL.LINEAR]],
		[[GL.NEAREST,GL.NEAREST_MIPMAP_NEAREST],[GL.LINEAR,GL.LINEAR_MIPMAP_NEAREST]],
		[[GL.NEAREST,GL.NEAREST_MIPMAP_LINEAR],[GL.LINEAR,GL.LINEAR_MIPMAP_LINEAR]],
	];
	
	static var TWRAP = [
		GL.CLAMP_TO_EDGE,
		GL.REPEAT,
	];
	
	static var FACES = [
		0,
		GL.FRONT, // front/back reversed wrt stage3d
		GL.BACK,
		GL.FRONT_AND_BACK,
	];
	
	static var BLEND = [
		GL.ONE,
		GL.ZERO,
		GL.SRC_ALPHA,
		GL.SRC_COLOR,
		GL.DST_ALPHA,
		GL.DST_COLOR,
		GL.ONE_MINUS_SRC_ALPHA,
		GL.ONE_MINUS_SRC_COLOR,
		GL.ONE_MINUS_DST_ALPHA,
		GL.ONE_MINUS_DST_COLOR,
		GL.CONSTANT_COLOR,
		GL.CONSTANT_ALPHA,
		GL.ONE_MINUS_CONSTANT_COLOR,
		GL.ONE_MINUS_CONSTANT_ALPHA,
		GL.SRC_ALPHA_SATURATE,
	];
	
	static var COMPARE = [
		GL.ALWAYS,
		GL.NEVER,
		GL.EQUAL,
		GL.NOTEQUAL,
		GL.GREATER,
		GL.GEQUAL,
		GL.LESS,
		GL.LEQUAL,
	];
	
	static var OP = [
		GL.FUNC_ADD,
		GL.FUNC_SUBTRACT,
		GL.FUNC_REVERSE_SUBTRACT
	];

}

#end
