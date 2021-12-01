module dub.exception;

//debug = IncludeInitiatorTrace;

import dub.internal.vibecompat.inet.path;
import dub.package_;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.format;

///
struct FileLocation
{
	import dub.internal.sdlang.util : SDLLocation = Location;

	NativePath filePath; /// Local file path
	int line; /// 1-indexed line number
	int column; /// 1-indexed column number
	size_t offset; /// Zero-indexed byte offset into the source

	this(int line, int column, size_t offset)
	{
		this.line = line;
		this.column = column;
		this.offset = offset;
	}

	this(NativePath filePath, int line, int column, size_t offset)
	{
		this.filePath = filePath;
		this.line = line;
		this.column = column;
		this.offset = offset;
	}

	this(SDLLocation loc)
	{
		filePath = NativePath(loc.file);
		line = loc.line + 1;
		column = loc.col + 1;
		offset = loc.index;
	}

	string toString() const
	{
		auto ret = appender!string;
		if (!filePath.empty)
			ret.put(filePath.toNativeString());

		if (line) {
			ret.put('(');
			ret.put(line.to!string);
			if (column) {
				ret.put(',');
				ret.put(column.to!string);
			}
			ret.put(')');
		} else if (offset) {
			ret.put("@byte(");
			ret.put(offset.to!string);
			ret.put(')');
		}
		return ret.data;
	}
}

/// Indicates a source where something was attempted to be loaded from.
/// No fields may be set in this struct, however at least one should be set.
struct LoadInitiator
{
	enum deprecation = "Associate a LoadInitiator or null to help trace package load issues for users";

	/// A parent package loaded this, possibly as sub-package or as dependency.
	Package package_;
	/// A file location that is the source for this load.
	FileLocation location;
	/// Debug dub source location.
	string internalFile;
	/// ditto
	size_t internalLine;

	/// The load was initiated by the user, e.g. via CLI
	enum cli = LoadInitiator.init;

	this(typeof(null), string file = __FILE__, size_t line = __LINE__)
	{
		// default init
		internalFile = file;
		internalLine = line;
	}

	this(Package package_, string file = __FILE__, size_t line = __LINE__)
	{
		internalFile = file;
		internalLine = line;
		this.package_ = package_;
	}

	this(FileLocation fileLocation, string file = __FILE__, size_t line = __LINE__)
	{
		internalFile = file;
		internalLine = line;
		this.location = fileLocation;
	}

	this(Package package_, FileLocation fileLocation, bool fromRecipe, string file = __FILE__, size_t line = __LINE__)
	{
		internalFile = file;
		internalLine = line;
		this.package_ = package_;
		this.location = fileLocation;

		if (!this.location.filePath.empty && !this.location.filePath.absolute) {
			this.location.filePath = this.package_.path ~ this.location.filePath;
		}

		if (this.location.filePath.empty && fromRecipe)
			this.location.filePath = this.package_.recipePath.empty
				? (this.package_.path ~ NativePath("dub.json_or_sdl"))
				: this.package_.recipePath;
	}

	// trace file/line when the struct is passed somewhere else (like reconstructing)
	ref LoadInitiator trace(string file = __FILE__, size_t line = __LINE__) return @safe pure nothrow @nogc
	{
		this.internalFile = file;
		this.internalLine = line;
		return this;
	}

	string toString() const
	{
		auto ret = appender!string;
		if (location != FileLocation.init) {
			if (package_ !is null)
			{
				if (location.filePath.empty)
					ret.put(format("%s @ %s%s", package_.name, package_.path, location));
				else
					ret.put(format("%s @ %s", package_.name, location));
			}
			else
				ret.put(location.toString());
		} else if (package_ !is null) {
			ret.put(format("%s %s @ %s",
				package_.name,
				package_.version_,
				package_.recipePath.empty
					? package_.path.toNativeString()
					: package_.recipePath.toNativeString()));
		}
		debug (IncludeInitiatorTrace) {
			if (internalLine && internalFile.length) {
				ret.put(format(" (%s:%d)", internalFile, internalLine));
			}
		}
		return ret.data;
	}

	bool opEquals(const LoadInitiator other) const
	{
		return package_ == other.package_ && location == other.location;
	}

	bool opEquals(const ref LoadInitiator other) const
	{
		return package_ == other.package_ && location == other.location;
	}

	size_t toHash() const nothrow
	{
		return hashOf(package_, hashOf(location));
	}
}

/** Exception that is thrown during DUB package loading.

	As packages can load sub-packages as dependencies, this can help find where
	an error actually originated from.

	The various sub-classes further describe what has gone wrong.
*/
abstract class PackageLoadException : Exception
{
	/// The package folder path that was attempted to be loaded but failed.
	NativePath root;
	/// The package(s) that started the load of this package or null if it was
	/// directly loaded. When unwinding the exception and populating with
	/// packages the topmost packages will be placed last in this array.
	LoadInitiator[] initiators;
	/// Optional version to associate to the package instead of the one declared
	/// in the package recipe, or the one determined by invoking the VCS
	/// (GIT currently).
	string version_override = "";

	this(NativePath root,
		string msg,
		LoadInitiator initiator = null,
		string version_override = "",
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable nextInChain = null
	)
	{
		super(msg, file, line, nextInChain);

		this.root = root;
		if (initiator != LoadInitiator.init)
			this.initiators = [initiator];
		this.version_override = version_override;
	}
}

/** Exception that is thrown when a dub package file (dub.json/dub.sdl) cannot
	be found.

	Packages are expected to be found in $(LREF dub.package_.packageInfoFiles)
*/
class MissingPackageFileException : PackageLoadException
{
	this(NativePath root,
		LoadInitiator initiator = null,
		string version_override = "",
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable nextInChain = null
	)
	{
		super(root, format("No package file found in %s, expected one of %s",
				root.toNativeString(),
				packageInfoFiles.map!(f => cast(string)f.filename).join("/")
			),
			initiator, version_override, file, line, nextInChain
		);
		try {
			import dub.internal.vibecompat.core.file : existsFile, getFileInfo;

			if (!existsFile(root))
				msg = format("Attempted to load package from directory %s, which does not exist (maybe misspelled?)", root.toNativeString());

			auto info = getFileInfo(root);
			if (!info.isDirectory)
				msg = format("Attempted to load package from %s, which is not a directory", root.toNativeString());
		} catch (Exception) { }
	}
}

class ToolchainMismatchException : PackageLoadException
{
	import dub.dependency : Dependency;

	Dependency minDubVersion;
	string dubVersion;

	this(NativePath root,
		Dependency minDubVersion,
		string dubVersion,
		LoadInitiator initiator = null,
		string version_override = "",
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable nextInChain = null
	)
	{
		super(root, "dub-" ~ dubVersion
			~ " does not comply with toolchainRequirements.dub "
			~ "specification: " ~ minDubVersion.toString()
			~ "\nPlease consider upgrading your DUB installation",
			initiator, version_override, file, line, nextInChain);

		this.minDubVersion = minDubVersion;
		this.dubVersion = dubVersion;
	}
}

/** 
 * Exception thrown when a path based dependency (such as
 * `dependency x path="/path/to/x"`)
 */
class DependencySpellingException : PackageLoadException
{
	string spelt, expected;

	this(NativePath root,
		string spelt,
		string expected,
		LoadInitiator initiator = null,
		string version_override = "",
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable nextInChain = null
	)
	{
		super(root, format("Path based dependency %s is referenced with a wrong name: %s vs. %s",
				root.toNativeString(), spelt, expected),
			initiator, version_override, file, line, nextInChain);

		this.spelt = spelt;
		this.expected = expected;
	}
}

