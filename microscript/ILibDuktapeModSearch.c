/*
Copyright 2006 - 2022 Intel Corporation

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#ifdef WIN32
#include <WinSock2.h>
#include <WS2tcpip.h>
#endif

#include "ILibDuktapeModSearch.h"
#include "microstack/ILibParsers.h"
#include "microscript/ILibDuktape_Helpers.h"
#include "microscript/duk_module_duktape.h"
#include <sys/stat.h>

#if defined(WIN32) && !defined(_WIN32_WCE) && !defined(_MINCORE)
#define _CRTDBG_MAP_ALLOC
#include <crtdbg.h>
#endif

#define ILibDuktape_ModSearch_ModuleFile		"\xFF_Modules_File"
#define ILibDuktape_ModSearch_ModuleFunc		"\xFF_Modules_Func"
#define ILibDuktape_ModSearch_ModuleFileDate	"\xFF_Modules_FileDate"
#define ILibDuktape_ModSearch_ModuleObject		"\xFF_Modules_Object"
#define ILibDuktape_ModSearch_ModuleFileSource	"\xFF_Modules_FileSource"


#define ILibDuktape_ModSearch_JSInclude			"\xFF_ModSearch_JSINCLUDE"
#define ILibDuktape_ModSearch_ModulePath		"\xFF_ModSearch_Path"
#define ILibDuktape_ModSearch_BuiltinDone		"\xFF_ModSearch_BuiltinDone"
#define ILibDuktape_ModSearch_Loaded			"\xFF_ModSearch_Loaded"

int ILibDuktape_ModSearch_ShowNames = 0;
int ILibDuktape_ModSearch_ModuleDiskMode = 0;	// 0 = never, 1 = only names without a built-in or pushed module, 2 = always

static int ILibDuktape_ModSearch_BuiltinModulesAreDone(duk_context *ctx);
static duk_ret_t mod_Search_Files(duk_context *ctx, char* id);

// Reads one field (key) of a module's table entry (id).
// Leaves the field's value on the stack, nothing when the entry or the field is missing.
static duk_ret_t ModSearchTable_Get(duk_context *ctx, duk_idx_t table, char *key, char *id)
{
	if (!duk_has_prop_string(ctx, table, id))
	{
		return(-1);
	}
	duk_get_prop_string(ctx, table, id);			// [table][...][module]
	if (!duk_has_prop_string(ctx, -1, key))
	{
		duk_pop(ctx);								// [table][...]
		return(-1);
	}
	duk_get_prop_string(ctx, -1, key);				// [table][...][module][value]
	duk_remove(ctx, -2);							// [table][...][value]
	return(1);
}
// Writes the value on the stack top as one field (key) of a module's table entry (id), and creates the entry when it is missing.
// Leaves nothing on the stack, the value is popped.
static duk_ret_t ModSearchTable_Put(duk_context *ctx, duk_idx_t table, char *key, char *id)
{
	if (!duk_has_prop_string(ctx, table, id))
	{
		duk_dup(ctx, table);						// [table][...][val][table]
		duk_push_object(ctx);						// [table][...][val][table][objtable]
		duk_put_prop_string(ctx, -2, id);			// [table][...][val][table]
		duk_pop(ctx);								// [table][...][val]
	}
	duk_dup(ctx, table);							// [table][...][val][table]
	duk_get_prop_string(ctx, -1, id);				// [table][...][val][table][objtable]
	duk_dup(ctx, -3);								// [table][...][val][table][objtable][val]
	duk_put_prop_string(ctx, -2, key);				// [table][...][val][table][objtable]
	duk_pop_3(ctx);									// [table][...]
	return(0);
}

// Pushes one field (key) of a module's table entry (id).
// Returns 1 with the value on the stack, 0 with nothing pushed when the entry or the field is missing.
static int ILibDuktape_ModSearch_PushTableField(duk_context *ctx, char *key, char *id)
{
	duk_push_heap_stash(ctx);											// [stash]
	duk_get_prop_string(ctx, -1, "ModSearchTable");						// [stash][table]
	if (ModSearchTable_Get(ctx, -1, key, id) > 0)						// [stash][table][value]
	{
		duk_remove(ctx, -2); duk_remove(ctx, -2);						// [value]
		return(1);
	}
	duk_pop_2(ctx);														// ...
	return(0);
}

// True for a name served by a native C binding, which require() takes before any disk file or table copy
static int ILibDuktape_ModSearch_IsNative(duk_context *ctx, char *id)
{
	if (ILibDuktape_ModSearch_PushTableField(ctx, ILibDuktape_ModSearch_ModuleFunc, id) == 0) { return(0); }
	duk_pop(ctx);
	return(1);
}

// The copy in the module table, without looking at disk files. addModule() compares against this, because the table is what it changes.
// Comparing against a disk file kept the built-in copy out of the table whenever a disk file with a higher version was present.
// Leaves the source text on the stack, nothing when there is no copy.
static int ILibDuktape_ModSearch_GetTableModule(duk_context *ctx, char *id)
{
	return(ILibDuktape_ModSearch_PushTableField(ctx, ILibDuktape_ModSearch_ModuleFile, id));
}

// Date of the table copy, a disk file is not looked at. Seconds since the epoch, 0 when the copy has no date or there is no copy
static uint32_t ILibDuktape_ModSearch_GetTableModuleDate(duk_context *ctx, char *id)
{
	uint32_t retVal;
	if (ILibDuktape_ModSearch_PushTableField(ctx, ILibDuktape_ModSearch_ModuleFileDate, id) == 0) { return(0); }
	retVal = (uint32_t)duk_get_uint(ctx, -1); duk_pop(ctx);
	return(retVal);
}

// Origin of the table copy: "server" for a copy added after the built-in set, else "internal"
static char* ILibDuktape_ModSearch_TableSource(duk_context *ctx, char *id)
{
	char *retVal;
	if (ILibDuktape_ModSearch_PushTableField(ctx, ILibDuktape_ModSearch_ModuleFileSource, id) == 0) { return("internal"); }
	retVal = (strcmp(duk_get_string(ctx, -1), "server") == 0) ? "server" : "internal"; duk_pop(ctx);
	return(retVal);
}

// A <module>.js file in the working directory used to win over every built-in and pushed module, so a file planted next to the binary ran with the agent's rights.
// DiskMode decides now: 0 loads no module file, 1 only a name the table has no module for (script mode), 2 any file (-allowDiskModules), 3 the same on a debug build.
// Returns 1 when the disk file for this id may be loaded, 0 when not.
static int ILibDuktape_ModSearch_DiskAllowed(duk_context *ctx, char *id)
{
	int mode = ILibDuktape_ModSearch_getJSModuleDiskMode();
	if (mode == 0) { return(0); }
	if (mode >= 2) { return(1); }
	if (ILibDuktape_ModSearch_GetTableModule(ctx, id) == 0) { return(1); }	// A name the table has no module for may come from disk in mode 1
	duk_pop(ctx);
	return(0);
}

// The disk mode the agent runs with, a debug build always reports 3.
// Returns 0, 1, 2 or 3, the meaning is in the DiskAllowed() comment above.
int ILibDuktape_ModSearch_getJSModuleDiskMode()
{
#ifdef _DEBUG
	return(3);
#else
	return(ILibDuktape_ModSearch_ModuleDiskMode);
#endif
}

// Returns the @module-version= of a module, 0 when it has none
// Only the first line counts, after a UTF-8 BOM (EF BB BF) and leading blank lines, the tag is case-insensitive, and nothing may stand between the tag, the = and the number
// Use a /*! comment in the module so minifiers keep it
static uint32_t ILibDuktape_ModSearch_ParseVersion(char *module, size_t moduleLen)
{
	static const char tag[] = "@module-version=";
	const size_t tagLen = sizeof(tag) - 1;
	size_t start = 0, end, i;
	uint32_t v = 0;

	if (moduleLen >= 3 && memcmp(module, "\xEF\xBB\xBF", 3) == 0) { start = 3; }
	while (start < moduleLen && (module[start] == ' ' || module[start] == '\t' || module[start] == '\r' || module[start] == '\n')) { ++start; }
	for (end = start; end < moduleLen && module[end] != '\r' && module[end] != '\n'; ++end) { }

	for (i = start; i + tagLen < end; ++i)
	{
		if (strncasecmp(module + i, tag, tagLen) != 0 || module[i + tagLen] < '0' || module[i + tagLen] > '9') { continue; }
		for (i += tagLen; i < end && module[i] >= '0' && module[i] <= '9'; ++i)
		{
			if (v > (0xFFFFFFFFu - (uint32_t)(module[i] - '0')) / 10) { return(0xFFFFFFFFu); }	// A number past 4294967295 counts as that, instead of wrapping to a small one
			v = (v * 10) + (uint32_t)(module[i] - '0');
		}
		return(v);
	}
	return(0);
}

// Pushes the disk file name of a module: <path>/<id>.js with the path from setModulePath(), or <id>.js in the working directory
static char* ILibDuktape_ModSearch_PushFileName(duk_context *ctx, char *id)
{
	char *mpath;
	duk_push_heap_stash(ctx);																						// [stash]
	mpath = Duktape_GetStringPropertyValue(ctx, -1, ILibDuktape_ModSearch_ModulePath, NULL);
	duk_pop(ctx);																									// ...
	return((char*)(mpath == NULL ? duk_push_sprintf(ctx, "%s.js", id) : duk_push_sprintf(ctx, "%s/%s.js", mpath, id)));	// [fileName]
}

// True when the module's disk file exists and the disk is allowed for the id, with its modification time in seconds since the epoch when asked for.
// A C stat(), because the statSync() evaluated from a C string threw inside the protected call for every id without a file, which a debugger reports as an uncaught error.
static int ILibDuktape_ModSearch_DiskFile(duk_context *ctx, char *id, uint32_t *mtime)
{
	int found = 0;
	char *fileName;
#ifdef WIN32
	struct _stat64 st;
#else
	struct stat st;
#endif
	if (ILibDuktape_ModSearch_DiskAllowed(ctx, id) == 0) { return(0); }
	fileName = ILibDuktape_ModSearch_PushFileName(ctx, id);				// [fileName]
#ifdef WIN32
	WCHAR wpath[4096];
	found = (MultiByteToWideChar(CP_UTF8, 0, fileName, -1, wpath, (int)(sizeof(wpath) / 2)) > 0 && _wstat64(wpath, &st) == 0) ? 1 : 0;
#else
	found = (stat(fileName, &st) == 0) ? 1 : 0;
#endif
	duk_pop(ctx);														// ...
	if (found != 0 && mtime != NULL) { *mtime = (uint32_t)st.st_mtime; }
	return(found);
}

// Date of a module's disk file when the disk is allowed for the id, otherwise the date of the table copy. Seconds since the epoch, 0 when neither has one
uint32_t ILibDuktape_ModSearch_GetJSModuleDate(duk_context *ctx, char *id)
{
	uint32_t mtime = 0;
	if (ILibDuktape_ModSearch_IsNative(ctx, id) != 0) { return(0); }
	if (ILibDuktape_ModSearch_DiskFile(ctx, id, &mtime) != 0) { return(mtime); }
	return(ILibDuktape_ModSearch_GetTableModuleDate(ctx, id));
}

// Drops the loaded instance of a module from require()'s cache, so the next require(id) goes through mod_Search() again and compiles the table copy.
// Code that holds the old instance keeps it, and a native name keeps its instance because require() would only build the same binding again. Duktape's own loader deletes an entry on a failed load, so the cache is written for this.
// The Duktape object comes from the global stash, the same place the loader reads it, so a core that reassigns the global cannot send this to another cache.
static void ILibDuktape_ModSearch_ForgetLoaded(duk_context *ctx, char *id)
{
	if (ILibDuktape_ModSearch_IsNative(ctx, id) != 0) { return; }
	duk_push_global_stash(ctx);										// [gstash]
	duk_get_prop_string(ctx, -1, "\xff" "module:Duktape");			// [gstash][Duktape]
	duk_get_prop_string(ctx, -1, "modLoaded");						// [gstash][Duktape][modLoaded]
	if (duk_is_object(ctx, -1)) { duk_del_prop_string(ctx, -1, id); }
	duk_pop_3(ctx);													// ...
}

// Source text of the copy that require() would compile, the disk file when allowed, else the table copy.
// Leaves the source text on the stack, nothing when there is no copy.
duk_ret_t ILibDuktape_ModSearch_GetJSModule(duk_context *ctx, char *id)
{
	if (ILibDuktape_ModSearch_DiskAllowed(ctx, id) != 0 && mod_Search_Files(ctx, id) == 1) { return(1); }	// [source]
	return(ILibDuktape_ModSearch_GetTableModule(ctx, id));
}

// Registers a ready-made JS object as module id, require() hands it out before anything else
void ILibDuktape_ModSearch_AddModuleObject(duk_context *ctx, char *id, void *heapptr)
{
	duk_push_heap_stash(ctx);											// [stash]
	duk_get_prop_string(ctx, -1, "ModSearchTable");						// [stash][table]
	duk_push_heapptr(ctx, heapptr);										// [stash][table][object]
	ModSearchTable_Put(ctx, -2, ILibDuktape_ModSearch_ModuleObject, id);// [stash][table]
	duk_pop_2(ctx);														// ...
}

// Seconds since the epoch of a date string, 0 for anything Date.parse() does not take or a date before 1970
static uint32_t ILibDuktape_ModSearch_ParseDate(duk_context *ctx, char *text)
{
	double ms = 0;
	if (text == NULL) { return(0); }
	duk_get_global_string(ctx, "Date");								// [Date]
	duk_get_prop_string(ctx, -1, "parse");							// [Date][parse]
	duk_push_string(ctx, text);										// [Date][parse][text]
	if (duk_pcall(ctx, 1) == 0) { ms = duk_get_number(ctx, -1); }	// [Date][ms or error]
	duk_pop_2(ctx);													// ...
	return((ms > 0 && ms < 4294967296000.0) ? (uint32_t)(ms / 1000) : 0);
}

// Writes a module's source text into the table unconditionally, with its origin and date. AddModuleChecked() is the one that decides whether to.
// Returns 0 always.
int ILibDuktape_ModSearch_AddModuleEx(duk_context *ctx, char *id, char *module, int moduleLen, char *mtime)
{
	duk_push_heap_stash(ctx);											// [stash]
	duk_get_prop_string(ctx, -1, "ModSearchTable");						// [stash][table]
	duk_push_lstring(ctx, module, moduleLen);							// [stash][table][module]
	ModSearchTable_Put(ctx, -2, ILibDuktape_ModSearch_ModuleFile, id);	// [stash][table]

	// Every module added while the agent registers its built-in set is "internal". A copy added after that came from the server's core, or from a script
	duk_push_string(ctx, ILibDuktape_ModSearch_BuiltinModulesAreDone(ctx) != 0 ? "server" : "internal");	// [stash][table][source]
	ModSearchTable_Put(ctx, -2, ILibDuktape_ModSearch_ModuleFileSource, id);	// [stash][table]

	if (mtime != NULL)
	{
		duk_push_uint(ctx, ILibDuktape_ModSearch_ParseDate(ctx, mtime));					// [stash][table][uint]
		ModSearchTable_Put(ctx, -2, ILibDuktape_ModSearch_ModuleFileDate, id);	// [stash][table]
	}
	else
	{
		// A copy that comes without a date can still replace a dated one, by its version. The old date would then be reported for the new code, so it is removed
		duk_get_prop_string(ctx, -1, id);									// [stash][table][entry]
		duk_del_prop_string(ctx, -1, ILibDuktape_ModSearch_ModuleFileDate);
		duk_pop(ctx);														// [stash][table]
	}
	duk_pop_2(ctx);																// ...
	return(0);
}
// Marks the end of the built-in module registration, every module added after this counts as "server"
void ILibDuktape_ModSearch_BuiltinModulesDone(duk_context *ctx)
{
	duk_push_heap_stash(ctx);											// [stash]
	duk_push_true(ctx);													// [stash][true]
	duk_put_prop_string(ctx, -2, ILibDuktape_ModSearch_BuiltinDone);	// [stash]
	duk_pop(ctx);														// ...
}
// Tells whether BuiltinModulesDone() was called for this heap.
// Returns 1 when it was, 0 while the built-in set is still being registered.
static int ILibDuktape_ModSearch_BuiltinModulesAreDone(duk_context *ctx)
{
	int ret;
	duk_push_heap_stash(ctx);											// [stash]
	ret = duk_has_prop_string(ctx, -1, ILibDuktape_ModSearch_BuiltinDone) ? 1 : 0;
	duk_pop(ctx);														// ...
	return(ret);
}

// Adds a copy of a module when it should replace what the table holds. The "@module-version" number decides, a version always wins over none, and an identical copy is never added again.
// With the same version and other content the version number was not raised, so the copy added after the built-in set wins, which is the server's or a script's. Without a version on either side the file date decides, and without dates the new copy always replaces.
// Returns 1 when this copy is now the one in the table (added, or already there), 0 when the existing copy is kept, -1 only if AddModuleEx() ever reports a failure (it returns 0 today).
int ILibDuktape_ModSearch_AddModuleChecked(duk_context *ctx, char *id, char *module, size_t moduleLen, char *mtime)
{
	int top = duk_get_top(ctx);
	int add = 0, identical = 0;
	uint32_t newVersion = ILibDuktape_ModSearch_ParseVersion(module, moduleLen);
	uint32_t oldVersion = 0;

	if (ILibDuktape_ModSearch_GetTableModule(ctx, id) != 0)					// [existing]
	{
		duk_size_t oldLen;
		char *old = (char*)duk_get_lstring(ctx, -1, &oldLen);
		if (old != NULL)
		{
			identical = (oldLen == moduleLen && memcmp(old, module, moduleLen) == 0) ? 1 : 0;
			oldVersion = ILibDuktape_ModSearch_ParseVersion(old, oldLen);
		}
	}
	duk_set_top(ctx, top);														// ...

	if (newVersion != oldVersion)
	{
		add = (newVersion > oldVersion) ? 1 : 0;
	}
	else if (identical == 1)
	{
		add = 0;
	}
	else if (newVersion != 0)
	{
		static int logged = 0;	// Once per process and so only for the first module, because every core start adds the modules again and a reconnecting agent would repeat the line at every connect
		add = ILibDuktape_ModSearch_BuiltinModulesAreDone(ctx);
		if (logged == 0) { logged = 1; ILIBLOGMESSAGEX("Module '%s' version %u was added again with different content, the %s copy is used", id, newVersion, add != 0 ? "new" : "existing"); }
	}
	else
	{
		uint32_t update = (mtime != NULL) ? ILibDuktape_ModSearch_ParseDate(ctx, mtime) : 0;
		uint32_t existing = ILibDuktape_ModSearch_GetTableModuleDate(ctx, id);
		if ((update > existing) || (update == existing && update == 0)) { add = 1; }
	}

	if (add != 0)
	{
		// A loaded instance is dropped from require()'s cache, so the next require() compiles this copy. Code that holds the old instance keeps it
		ILibDuktape_ModSearch_ForgetLoaded(ctx, id);
		if (ILibDuktape_ModSearch_AddModuleEx(ctx, id, module, (int)moduleLen, mtime) != 0) { return(-1); }
	}
	return((add != 0 || identical != 0) ? 1 : 0);
}

// Pushes an array with the names of every module the table holds source text for, plus the native bindings when includeNative is set. Module objects are not in it
void ILibDuktape_ModSearch_PushModuleNames(duk_context *ctx, int includeNative)
{
	char *id;
	duk_idx_t top;
	duk_push_heap_stash(ctx);											// [stash]
	duk_get_prop_string(ctx, -1, "ModSearchTable");						// [stash][table]
	duk_enum(ctx, -1, DUK_ENUM_OWN_PROPERTIES_ONLY);					// [stash][table][enum]
	duk_push_array(ctx);												// [stash][table][enum][array]
	top = duk_get_top(ctx);
	while (duk_next(ctx, -2, 0))										// [stash][table][enum][array][key]
	{
		id = (char*)duk_to_string(ctx, -1);
		if (ModSearchTable_Get(ctx, -4, ILibDuktape_ModSearch_ModuleFile, id) > 0 || (includeNative != 0 && ModSearchTable_Get(ctx, -4, ILibDuktape_ModSearch_ModuleFunc, id) > 0))
		{																// [stash][table][enum][array][key][value]
			duk_pop(ctx);												// [stash][table][enum][array][key]
			duk_array_push(ctx, -2);									// [stash][table][enum][array]
		}
		duk_set_top(ctx, top);
	}
	duk_remove(ctx, -2); duk_remove(ctx, -2); duk_remove(ctx, -2);		// [array]
}

// Pushes a copy of the list of modules that were loaded, each with the source ("native", "disk", "internal", "server" or "db"), version and date of the copy that was loaded.
// The getJSModule...() calls describe the copy a new require() would get. This list says what is really running, which differs once a module is replaced after it was loaded.
void ILibDuktape_ModSearch_PushLoaded(duk_context *ctx)
{
	duk_push_heap_stash(ctx);											// [stash]
	if (duk_has_prop_string(ctx, -1, ILibDuktape_ModSearch_Loaded))
	{
		duk_get_prop_string(ctx, -1, ILibDuktape_ModSearch_Loaded);		// [stash][loaded]
		duk_json_encode(ctx, -1);										// [stash][json]
		duk_json_decode(ctx, -1);										// [stash][copy]
	}
	else
	{
		duk_push_object(ctx);											// [stash][empty]
	}
	duk_remove(ctx, -2);												// [list]
}

// Writes the module trace line "ModuleLoader: <name>, <source>, <version>" to the console and the agent log, enabled with "showModuleNames" in the .db
static void mod_Search_Trace(char *id, char *from, uint32_t version)
{
	if (ILibDuktape_ModSearch_ShowNames == 0) { return; }
	printf("ModuleLoader: %s, %s, %u\n", id, from, (unsigned int)version);
	ILIBLOGMESSAGEX("ModuleLoader: %s, %s, %u", id, from, (unsigned int)version);
}

// Records the copy that was just loaded for getJSModulesLoaded() and writes its trace line.
// Expects the module's source on top of the stack, anything else there gives version 0. Leaves the stack as it found it.
static void mod_Search_Loaded(duk_context *ctx, char *id, char *from, uint32_t date)
{
	duk_size_t sourceLen;
	int top = duk_get_top(ctx);
	char *source = (char*)duk_get_lstring(ctx, -1, &sourceLen);
	uint32_t version = (source != NULL) ? ILibDuktape_ModSearch_ParseVersion(source, sourceLen) : 0;

	mod_Search_Trace(id, from, version);
	duk_push_heap_stash(ctx);											// [stash]
	if (!duk_has_prop_string(ctx, -1, ILibDuktape_ModSearch_Loaded))
	{
		duk_push_object(ctx);											// [stash][loaded]
		duk_put_prop_string(ctx, -2, ILibDuktape_ModSearch_Loaded);		// [stash]
	}
	duk_get_prop_string(ctx, -1, ILibDuktape_ModSearch_Loaded);			// [stash][loaded]
	duk_push_object(ctx);												// [stash][loaded][info]
	duk_push_string(ctx, from); duk_put_prop_string(ctx, -2, "source");
	duk_push_uint(ctx, version); duk_put_prop_string(ctx, -2, "version");
	duk_push_uint(ctx, date); duk_put_prop_string(ctx, -2, "date");
	duk_put_prop_string(ctx, -2, id);									// [stash][loaded]
	duk_set_top(ctx, top);
}

// Registers a native C binding as module id, require() calls the handler to build the module object.
// Returns 0 always.
int ILibDuktape_ModSearch_AddHandler(duk_context *ctx, char *id, ILibDuktape_ModSearch_PUSH_Object handler)
{
	duk_push_heap_stash(ctx);											// [stash]
	duk_get_prop_string(ctx, -1, "ModSearchTable");						// [stash][table]
	duk_push_pointer(ctx, (void*)handler);								// [stash][table][ptr]
	ModSearchTable_Put(ctx, -2, ILibDuktape_ModSearch_ModuleFunc, id);	// [stash][table]
	duk_pop_2(ctx);														// ...
	return(0);
}

// Reads a module's disk file, without checking whether the disk is allowed. The caller does that.
// Leaves the source text on the stack, nothing when the file is missing or empty.
static duk_ret_t mod_Search_Files(duk_context *ctx, char* id)
{
	char *data;
	int dataLen = ILibReadFileFromDiskEx(&data, ILibDuktape_ModSearch_PushFileName(ctx, id));	// [fileName]
	duk_pop(ctx);																				// ...
	if (dataLen > 0)
	{
		duk_push_lstring(ctx, data, dataLen);													// [source]
		free(data);
		return 1;
	}
	return(0);
}
// Pushes { source, version, date } of the JavaScript copy require() would load now, the disk file when allowed, else the table copy. A native binding of the same name is not looked at.
// Returns 1 with the object on the stack, 0 with nothing pushed when there is no JavaScript copy.
static int ILibDuktape_ModSearch_PushJSCopyInfo(duk_context *ctx, char *id)
{
	char *source, *text;
	duk_size_t textLen;
	uint32_t date = 0;

	if (ILibDuktape_ModSearch_DiskFile(ctx, id, &date) != 0 && mod_Search_Files(ctx, id) == 1)		// [text]
	{
		source = "disk";
	}
	else if (ILibDuktape_ModSearch_GetTableModule(ctx, id) != 0)									// [text]
	{
		source = ILibDuktape_ModSearch_TableSource(ctx, id);
		date = ILibDuktape_ModSearch_GetTableModuleDate(ctx, id);
	}
	else
	{
		return(0);
	}

	text = (char*)duk_get_lstring(ctx, -1, &textLen);
	duk_push_object(ctx);																			// [text][info]
	duk_push_string(ctx, source); duk_put_prop_string(ctx, -2, "source");
	duk_push_uint(ctx, (text != NULL) ? ILibDuktape_ModSearch_ParseVersion(text, textLen) : 0); duk_put_prop_string(ctx, -2, "version");
	duk_push_uint(ctx, date); duk_put_prop_string(ctx, -2, "date");
	duk_remove(ctx, -2);																			// [info]
	return(1);
}

// Pushes { source, version, date } for the copy that require() would load now, the shape of a PushLoaded() entry, or null when there is no module with that name.
// The source is "native", "disk", "internal" or "server". The version is 0 for a copy without a version line or a native one, the date is 0 for a copy without one.
// A native name that also has a JavaScript copy gets that copy as "ignored", because require() never loads it. A copy that only the .db holds is not looked at, PushLoaded() lists it as "db" once it was loaded.
void ILibDuktape_ModSearch_PushInfo(duk_context *ctx, char *id)
{
	if (ILibDuktape_ModSearch_IsNative(ctx, id) != 0)
	{
		duk_push_object(ctx);													// [info]
		duk_push_string(ctx, "native"); duk_put_prop_string(ctx, -2, "source");
		duk_push_uint(ctx, 0); duk_put_prop_string(ctx, -2, "version");
		duk_push_uint(ctx, 0); duk_put_prop_string(ctx, -2, "date");
		if (ILibDuktape_ModSearch_PushJSCopyInfo(ctx, id) != 0) { duk_put_prop_string(ctx, -2, "ignored"); }	// [info]
	}
	else if (ILibDuktape_ModSearch_PushJSCopyInfo(ctx, id) == 0)
	{
		duk_push_null(ctx);														// [null]
	}
}

// Tells the script that a module was just loaded from a disk file, as process.on('diskModule', function (name) {}). With -allowDiskModules the core reports each such load to the server.
// Leaves the stack as it found it. A missing process object or a throwing listener is ignored, because a module load must not fail over a report.
static void mod_Search_EmitDiskModule(duk_context *ctx, char *id)
{
	int top = duk_get_top(ctx);

	duk_push_global_object(ctx);										// [g]
	duk_get_prop_string(ctx, -1, "process");							// [g][process]
	if (duk_is_object(ctx, -1))
	{
		duk_get_prop_string(ctx, -1, "emit");							// [g][process][emit]
		if (duk_is_function(ctx, -1))
		{
			duk_swap_top(ctx, -2);										// [g][emit][this]
			duk_push_string(ctx, "diskModule");							// [g][emit][this][diskModule]
			duk_push_string(ctx, id);									// [g][emit][this][diskModule][name]
			duk_pcall_method(ctx, 2);									// [g][result]
		}
	}
	duk_set_top(ctx, top);
}

// Called from inside a native handler: JS source that require() compiles as the module's code, after the handler has set the exports
void ILibDuktape_ModSearch_AddHandler_AlsoIncludeJS(duk_context *ctx, char *js, size_t jsLen)
{
	duk_push_heap_stash(ctx);										// [stash]
	duk_push_lstring(ctx, js, jsLen);								// [stash][str]
	duk_put_prop_string(ctx, -2, ILibDuktape_ModSearch_JSInclude);	// [stash]
	duk_pop(ctx);													// ...
}

// Duktape's Duktape.modSearch hook behind require(): module object, native binding, disk file when allowed, table copy, then the .db cache.
// Gives Duktape the source text to compile, or undefined when the exports are set already (object, or native without include JS). Throws when nothing has the module.
duk_ret_t mod_Search(duk_context *ctx)
{
	duk_size_t idLen;
	char *id;
	ILibDuktape_ModSearch_PUSH_Object func = NULL;
	void *chain;
	ILibSimpleDataStore mDS = NULL;
	uint32_t mtime = 0;
	char key[9 + DUK_COMMONJS_MODULE_ID_LIMIT];		// "__MODULE:" plus the longest id Duktape resolves, NUL included

	if (!duk_is_string(ctx, 0)) { return ILibDuktape_Error(ctx, "mod_search(): Invalid 'ID' parameter"); }
	id = (char*)duk_get_lstring(ctx, 0, &idLen);

	duk_push_current_function(ctx);													// [func]
	duk_get_prop_string(ctx, -1, "chain");											// [func][chain]
	chain = duk_to_pointer(ctx, -1);

	duk_get_prop_string(ctx, -2, "SimpleDS");										// [func][chain][DB]
	mDS = (ILibSimpleDataStore)duk_to_pointer(ctx, -1);

	duk_push_heap_stash(ctx);														// [func][chain][DB][stash]
	duk_get_prop_string(ctx, -1, "ModSearchTable");									// [func][chain][DB][stash][table]

	// First check if there is a JS Object override
	if (ModSearchTable_Get(ctx, -1, ILibDuktape_ModSearch_ModuleObject, id) > 0)	// [func][chain][DB][stash][table][obj]
	{
		mod_Search_Trace(id, "object", 0);
		duk_put_prop_string(ctx, 3, "exports");										// [func][chain][DB][stash][table]
		return(0);
	}

	// Check if there is a native handler
	if (ModSearchTable_Get(ctx, -1, ILibDuktape_ModSearch_ModuleFunc, id) > 0)		// [func][chain][DB][stash][table][ptr]
	{
		// Init this temp value, to detect if the module wants to add JS code
		duk_del_prop_string(ctx, -3, ILibDuktape_ModSearch_JSInclude);
		func = (ILibDuktape_ModSearch_PUSH_Object)duk_get_pointer(ctx, -1);

		func(ctx, chain);															// [func][chain][DB][stash][table][ptr][obj]
		duk_put_prop_string(ctx, 3, "exports");										// [func][chain][DB][stash][table][ptr]
		mod_Search_Loaded(ctx, id, "native", 0);
		if (!duk_has_prop_string(ctx, -3, ILibDuktape_ModSearch_JSInclude)) { return(0); }
		duk_get_prop_string(ctx, -3, ILibDuktape_ModSearch_JSInclude);			// [func][chain][DB][stash][table][ptr][js]
		return(1);
	}

	// DiskFile() applies the disk mode and gives the file date from the one stat()
	if (ILibDuktape_ModSearch_DiskFile(ctx, id, &mtime) != 0 && mod_Search_Files(ctx, id) == 1)
	{																				// [func][chain][DB][stash][table][source]
		// A disk file that replaces a built-in or pushed module goes into the agent log. A script's own helper module does not
		if (ModSearchTable_Get(ctx, -2, ILibDuktape_ModSearch_ModuleFile, id) > 0)
		{
			duk_pop(ctx);															// [func][chain][DB][stash][table][source]
			ILIBLOGMESSAGEX("Module '%s' was loaded from the file %s, in place of the built-in or pushed copy", id, ILibDuktape_ModSearch_PushFileName(ctx, id));
			duk_pop(ctx);															// [func][chain][DB][stash][table][source]
		}
		mod_Search_Loaded(ctx, id, "disk", mtime);
		mod_Search_EmitDiskModule(ctx, id);
		return(1);
	}

	if (ModSearchTable_Get(ctx, -1, ILibDuktape_ModSearch_ModuleFile, id) > 0)		// [func][chain][DB][stash][table][source]
	{
		mod_Search_Loaded(ctx, id, ILibDuktape_ModSearch_TableSource(ctx, id), ILibDuktape_ModSearch_GetTableModuleDate(ctx, id));
		return(1);
	}

	// Last the .db cache. Only a direct Duktape.modSearch() call can pass a longer id, and sprintf_s() on Windows would end the process for it instead of truncating
	if (mDS != NULL && idLen + 9 < sizeof(key))
	{
		int keyLen = sprintf_s(key, sizeof(key), "__MODULE:%s", id);
		int valueLen = ILibSimpleDataStore_GetEx(mDS, key, keyLen, NULL, 0);
		if (valueLen > 0)
		{
			char *value = (char*)ILibMemory_Allocate(valueLen, 0, NULL, NULL);
			ILibSimpleDataStore_GetEx(mDS, key, keyLen, value, valueLen);
			duk_push_lstring(ctx, value, valueLen);									// [func][chain][DB][stash][table][source]
			free(value);
			mod_Search_Loaded(ctx, id, "db", 0);
			return(1);
		}
	}

	mod_Search_Trace(id, "not found", 0);
	return(ILibDuktape_Error(ctx, "Module: %s (NOT FOUND)", id));
}

// JS: setModulePath(path), the folder disk modules are read from instead of the working directory.
// Gives undefined to JS, throws "Invalid Path" when path is not a string.
duk_ret_t ILibDuktape_ModSearch_setModulePath(duk_context *ctx)
{
	if (duk_is_string(ctx, 0))
	{
		duk_push_heap_stash(ctx);
		duk_dup(ctx, 0);
		duk_put_prop_string(ctx, -2, ILibDuktape_ModSearch_ModulePath);
		// Logged here in C because a JavaScript caller can bypass a wrapper in the core, but not this line
		ILIBLOGMESSAGEX("setModulePath: module files are read from '%s' instead of the working directory", (char*)duk_get_string(ctx, 0));
	}
	else
	{
		return(ILibDuktape_Error(ctx, "Invalid Path"));
	}
	
	return(0);
}

// Sets up require() for a heap: Duktape's module loader, the mod_Search() hook, the setModulePath() global and an empty module table
void ILibDuktape_ModSearch_Init(duk_context * ctx, void * chain, ILibSimpleDataStore mDB)
{
	duk_module_duktape_init(ctx);
	if (duk_ctx_chain(ctx) == NULL) { duk_ctx_context_data(ctx)->chain = chain; }

	duk_get_global_string(ctx, "Duktape");		// [globalString]
	duk_push_c_function(ctx, mod_Search, 4);	// [globalString][func]
	duk_push_pointer(ctx, chain);				// [globalString][func][chain]
	duk_put_prop_string(ctx, -2, "chain");		// [globalString][func]

	if (mDB != NULL)
	{
		duk_push_pointer(ctx, mDB);					// [globalString][func][DB]
		duk_put_prop_string(ctx, -2, "SimpleDS");	// [globalString][func]
	}

	duk_put_prop_string(ctx, -2, "modSearch");	// [globalString]
	duk_pop(ctx);								// ...

	duk_push_global_object(ctx);				// [g]
	ILibDuktape_CreateInstanceMethod(ctx, "setModulePath", ILibDuktape_ModSearch_setModulePath, 1);
	duk_pop(ctx);								// ...


	duk_push_heap_stash(ctx);							// [stash]
	duk_push_object(ctx);								// [stash][table]
	duk_put_prop_string(ctx, -2, "ModSearchTable");		// [stash]
	duk_pop(ctx);										// ...
}
