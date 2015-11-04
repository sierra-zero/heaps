package h3d.scene;

class WorldChunk {

	public var cx : Int;
	public var cy : Int;
	public var x : Float;
	public var y : Float;

	public var root : h3d.scene.Object;
	public var buffers : Map<Int, h3d.scene.Mesh>;
	public var bounds : h3d.col.Bounds;

	public function new(cx, cy) {
		this.cx = cx;
		this.cy = cy;
		root = new h3d.scene.Object();
		buffers = new Map();
		bounds = new h3d.col.Bounds();
	}

	public function dispose() {
		root.remove();
		root.dispose();
	}

}

class WorldModelMaterial {
	public var t : h3d.mat.BigTexture.BigTextureElement;
	public var m : hxd.fmt.hmd.Data.Material;
	public var bits : Int;
	public var startVertex : Int;
	public var startIndex : Int;
	public var vertexCount : Int;
	public var indexCount : Int;
	public function new(m, t) {
		this.m = m;
		this.t = t;
		this.bits = t.blend.getIndex() | (t.t.id << 3);
	}
}

class WorldModel {
	public var r : hxd.res.FbxModel;
	public var stride : Int;
	public var buf : hxd.FloatBuffer;
	public var idx : hxd.IndexBuffer;
	public var materials : Array<WorldModelMaterial>;
	public var bounds : h3d.col.Bounds;
	public function new(r) {
		this.r = r;
		this.buf = new hxd.FloatBuffer();
		this.idx = new hxd.IndexBuffer();
		this.materials = [];
		bounds = new h3d.col.Bounds();
	}
}

class World extends Object {

	var chunkBits : Int;
	var chunkSize : Int;
	var worldSize : Int;
	var worldStride : Int;
	var bigTextureSize = 2048;
	var bigTextureBG = 0xFF8080FF;
	var soilColor = 0x408020;
	var chunks : Array<WorldChunk>;
	var allChunks : Array<WorldChunk>;
	var bigTextures : Array<h3d.mat.BigTexture>;
	var textures : Map<String, h3d.mat.BigTexture.BigTextureElement>;

	public function new( chunkSize : Int, worldSize : Int, ?parent ) {
		super(parent);
		chunks = [];
		bigTextures = [];
		allChunks = [];
		textures = new Map();
		this.chunkBits = 1;
		while( chunkSize > (1 << chunkBits) )
			chunkBits++;
		this.chunkSize = 1 << chunkBits;
		this.worldSize = worldSize;
		this.worldStride = Math.ceil(worldSize / chunkSize);
	}

	function buildFormat() {
		return {
			fmt : [
				new hxd.fmt.hmd.Data.GeometryFormat("position", DVec3),
				new hxd.fmt.hmd.Data.GeometryFormat("normal", DVec3),
				new hxd.fmt.hmd.Data.GeometryFormat("uv", DVec2),
			],
			defaults : [],
		};
	}

	function getBlend( r : hxd.res.Image ) : h3d.mat.BlendMode {
		if( r.entry.extension == "jpg" )
			return None;
		return Alpha;
	}

	function loadMaterialTexture( r : hxd.res.FbxModel, mat : hxd.fmt.hmd.Data.Material ) {
		var texturePath = r.entry.directory + mat.diffuseTexture.split("/").pop();
		var t = textures.get(texturePath);
		if( t != null )
			return t;
		var rt = hxd.res.Loader.currentInstance.load(texturePath).toImage();
		var blend = getBlend(rt);
		for( b in bigTextures ) {
			t = b.add(rt, blend);
			if( t != null ) break;
		}
		if( t == null ) {
			var b = new h3d.mat.BigTexture(bigTextures.length, bigTextureSize, bigTextureBG);
			bigTextures.unshift(b);
			t = b.add(rt, blend);
			if( t == null ) throw "Texture " + texturePath + " is too big";
		}
		return t;
	}

	public function done() {
		for( b in bigTextures )
			b.done();
	}

	public function loadModel( r : hxd.res.FbxModel ) : WorldModel {
		var lib = r.toHmd();
		var models = lib.header.models;
		var format = buildFormat();

		var model = new WorldModel(r);
		model.stride = 0;
		for( f in format.fmt )
			model.stride += f.format.getSize();

		var startVertex = 0, startIndex = 0;
		for( m in models ) {
			var geom = lib.header.geometries[m.geometry];
			if( geom == null ) continue;
			var pos = m.position.toMatrix();
			for( mid in 0...m.materials.length ) {
				var mat = lib.header.materials[m.materials[mid]];
				var tex = loadMaterialTexture(r, mat);
				if( tex == null ) continue;
				var data = lib.getBuffers(geom, format.fmt, format.defaults, mid);

				var m = new WorldModelMaterial(mat, tex);
				m.vertexCount = Std.int(data.vertexes.length / model.stride);
				m.indexCount = data.indexes.length;
				m.startVertex = startVertex;
				m.startIndex = startIndex;
				model.materials.push(m);

				var vl = data.vertexes;
				var p = 0;
				var extra = model.stride - 8;
				for( i in 0...m.vertexCount ) {
					var x = vl[p++];
					var y = vl[p++];
					var z = vl[p++];
					var nx = vl[p++];
					var ny = vl[p++];
					var nz = vl[p++];
					var u = vl[p++];
					var v = vl[p++];

					// position
					var pt = new h3d.Vector(x,y,z);
					pt.transform3x4(pos);
					model.buf.push(pt.x);
					model.buf.push(pt.y);
					model.buf.push(pt.z);
					model.bounds.addPos(pt.x, pt.y, pt.z);

					// normal
					var n = new h3d.Vector(nx, ny, nz);
					n.transform3x3(pos);
					var len = hxd.Math.invSqrt(n.lengthSq());
					model.buf.push(n.x * len);
					model.buf.push(n.y * len);
					model.buf.push(n.z * len);

					// uv
					model.buf.push(u * tex.su + tex.du);
					model.buf.push(v * tex.sv + tex.dv);

					// extra
					for( k in 0...extra )
						model.buf.push(vl[p++]);
				}

				for( i in 0...m.indexCount )
					model.idx.push(data.indexes[i] + startIndex);

				startVertex += m.vertexCount;
				startIndex += m.indexCount;
			}
		}
		return model;
	}

	function getChunk( x : Float, y : Float, create = false ) {
		var ix = Std.int(x) >> chunkBits;
		var iy = Std.int(y) >> chunkBits;
		if( ix < 0 ) ix = 0;
		if( iy < 0 ) iy = 0;
		var cid = ix + iy * worldStride;
		var c = chunks[cid];
		if( c == null && create ) {
			c = new WorldChunk(ix, iy);
			c.x = ix * chunkSize;
			c.y = iy * chunkSize;
			addChild(c.root);
			chunks[cid] = c;
			allChunks.push(c);
			initSoil(c);
		}
		return c;
	}

	function initSoil( c : WorldChunk ) {
		var cube = new h3d.prim.Cube(chunkSize, chunkSize, 0);
		cube.addNormals();
		cube.addUVs();
		var soil = new h3d.scene.Mesh(cube, c.root);
		soil.x = c.x;
		soil.y = c.y;
		soil.material.texture = h3d.mat.Texture.fromColor(soilColor);
		soil.material.shadows = true;
	}

	function initMaterial( mesh : h3d.scene.Mesh, mat : WorldModelMaterial ) {
		mesh.material.blendMode = mat.t.blend;
		mesh.material.texture = mat.t.t.tex;
		mesh.material.mainPass.enableLights = true;
		mesh.material.shadows = true;
	}

	override function dispose() {
		super.dispose();
		for( c in allChunks )
			c.dispose();
		allChunks = [];
		chunks = [];
	}

	public function add( model : WorldModel, x : Float, y : Float, z : Float, scale = 1., rotation = 0. ) {
		var c = getChunk(x, y, true);

		for( mat in model.materials ) {
			var b = c.buffers.get(mat.bits);
			if( b == null ) {
				b = new h3d.scene.Mesh(new h3d.prim.BigPrimitive(model.stride, true), c.root);
				c.buffers.set(mat.bits, b);
				initMaterial(b, mat);
			}
			var p = Std.instance(b.primitive, h3d.prim.BigPrimitive);
			p.addSub(model.buf, model.idx, mat.startVertex, Std.int(mat.startIndex / 3), mat.vertexCount, Std.int(mat.indexCount / 3), x, y, z, rotation, scale);
		}


		// update bounds
		var cosR = Math.cos(rotation);
		var sinR = Math.sin(rotation);

		inline function addPoint(dx:Float, dy:Float, dz:Float) {
			var tx = dx * cosR - dy * sinR;
			var ty = dx * sinR + dy * cosR;
			c.bounds.addPos(tx * scale + x, ty * scale + y, dz * scale + z);
		}

		addPoint(model.bounds.xMin, model.bounds.yMin, model.bounds.zMin);
		addPoint(model.bounds.xMin, model.bounds.yMin, model.bounds.zMax);
		addPoint(model.bounds.xMin, model.bounds.yMax, model.bounds.zMin);
		addPoint(model.bounds.xMin, model.bounds.yMax, model.bounds.zMax);
		addPoint(model.bounds.xMax, model.bounds.yMin, model.bounds.zMin);
		addPoint(model.bounds.xMax, model.bounds.yMin, model.bounds.zMax);
		addPoint(model.bounds.xMax, model.bounds.yMax, model.bounds.zMin);
		addPoint(model.bounds.xMax, model.bounds.yMax, model.bounds.zMax);
	}

	override function sync(ctx:RenderContext) {
		super.sync(ctx);
		for( c in allChunks )
			c.root.visible = c.bounds.inFrustum(ctx.camera.m);
	}

}