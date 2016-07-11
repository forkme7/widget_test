#!/usr/bin/env iced
fs          = require 'fs'
path        = require 'path'
{make_esc}  = require 'iced-error'
{exec}      = require 'child_process'
iced.catchExceptions (str) -> console.error str


# =================================================================================
#
# Forgive messy code! I'm hacking on this from every angle while I play with results
#  - coyne
#
# This file is an exploration of how to display activity inside KBFS in the widget,
# by not giving too much attention to any one folder.
#
# I actually can't tell who the last editor of a file was, which is crucial info,
# so I pick randomly based on the writers of a folder.
#
# =================================================================================




##=======================================================================

TEST_TLF_LIMIT               = Infinity # crank to low val (10) for faster incomplete results
ROWS_TO_SHOW                 = 20   # how many "rows" show up in the widget; a row is a TLF*user section
MAX_ACTIVITY_PER_ROW         = 20   # max files inside a row (some can be inside "show more")
COLLAPSE_AT_PER_ROW          = 5    # items after this number are collapsed
COLLAPSE_HOURS_PER_ROW       = 24*7 # items this many hours older than first item in row are collapsed
TARGET_FRACTION_PUBLIC       = 0.5  # try to get approx this many rows public
IGNORE_FILES_DATED_IN_FUTURE = true # there are files in my KBFS from 2185 A.D.
TLFS_TO_EXCLUDE_IN_TESTING   = [    # e.g., "/keybase/private/foo" if you want to exclude that from test res
]

#
# The following regexps should probably be expanded upon and not just used by the widget, but
# also by notifications.
#
IGNORE_REGEXP =
  ///
     ( .git\/ )     # anything in a .git directory
   | ( \/\._ )         # ._FILES made in OSX
   | (thumbs\.db$)     # some common OS files and temp files...
   | (desktop\.ini$)
   | (Icon\r$)
   | (~$)              #  some_temp_file~
   | (\#[^\/]*\#$)     #  #some_temp_file#
   | (.DS_Store$)
   | (.keybasa\/)      # anything else to exclude?
  ///

##=======================================================================

class File

  constructor: ({@tlf, @path, @stat, @when_edited}) ->
    # since we have no last_writer, we guess
    @writer = @_assignRandomWriter()

  getWriter: -> @writer

  getMTime: -> @stat.mtime

  # -------------------------------------------------------------
  # PRIVATE
  # -------------------------------------------------------------

  _assignRandomWriter: ->
    candidates = @tlf.getWriters()
    return candidates[Math.floor(Math.random() * candidates.length)]

# =================================================================================

class Tlf

  constructor: ({@path}) ->
    @files = []
    @tlfParticipants = {}

  isPublic: ->
    ! @path.match /^\/keybase\/private\//

  getWriters: -> @path.split(path.sep)[3].split("#")[0].split(",")

  getTlfParticipants: -> (v for k,v of @tlfParticipants)

  hunt: (_, cb) ->
    esc = make_esc cb, "Tlf::hunt"
    files = []
    await @_huntRecurse {fpath: @path, files}, esc defer()
    console.log "In #{@path} found #{files.length} files."
    @files = files
    cb null

  # -------------------------------------------------------------
  # PRIVATE
  # -------------------------------------------------------------

  _huntRecurse: ({files, fpath}, cb) ->
    esc = make_esc cb, "Tlf::_huntRecurse"
    await fs.readdir fpath, esc defer children
    unless err?
      for c in children
        cpath = path.join fpath, c
        await fs.lstat cpath, esc defer stat
        if  stat.symlink
          console.log "skipping #{cpath} due to symlink status"
        else
          if stat.isDirectory()
            await @_huntRecurse {files, fpath: cpath}, esc defer()
          else
            @_maybeNoteFile {path: cpath, stat, files}
    cb null

  _maybeNoteFile: ({path, stat, files}) ->
    if path.match IGNORE_REGEXP
      console.log "Ignoring #{path} due to regexp match"
      return
    else if (stat.mtime > new Date()) and IGNORE_FILES_DATED_IN_FUTURE
      console.log "Ignoring #{path} since it was made in the FUTURE!"
      return
    else
      file = new File {tlf: @, path, stat}
      writer = file.getWriter()
      files.push file
      @tlfParticipants[writer] or= new TlfParticipant ({tlf: @, writer})
      @tlfParticipants[writer].noteFile {file}


# =================================================================================

class TlfParticipant
  # This corresponds to one person crossed with their recent write activity
  # in a TLF.
  constructor: ({@tlf, @writer}) ->
    @lastFiles   = []

  noteFile: ({file}) ->
    @lastFiles.push file
    # obviously faster way of keeping latest N when it matters
    @lastFiles.sort (a,b) -> b.stat.mtime - a.stat.mtime
    if @lastFiles.length > MAX_ACTIVITY_PER_ROW
      @lastFiles = @lastFiles[...MAX_ACTIVITY_PER_ROW]

  getLastFiles: -> @lastFiles

  getWriter: -> @writer

  getMTime: -> @lastFiles[0].stat.mtime

# =================================================================================
# OUR ACTUAL CODE FOR SELECTION FOLLOWS
# =================================================================================

getAllTlfParticipants = (_, cb) ->
  ###
  This function traverses all TLF's on your computer
  and returns TlfParticipant instances
  ###
  esc = make_esc cb, "getAllTlfParticipants"
  tlfs = []
  tlfParticipants = []
  for dir in ["/keybase/private", "/keybase/public"]
    await fs.readdir dir, esc defer tlfNames
    tlfNames = (tlfName for tlfName in tlfNames when path.join(dir,tlfName) not in TLFS_TO_EXCLUDE_IN_TESTING)
    for tlfName in tlfNames[...TEST_TLF_LIMIT]
      tlf = new Tlf {path: path.join(dir, tlfName)}
      await tlf.hunt null, defer err
      if err
        console.error err
      else
        tlfs.push tlf
        tlfParticipants = tlfParticipants.concat tlf.getTlfParticipants()

  cb null, {tlfs, tlfParticipants}

# =================================================================================

timeDisp = (d) ->
  sec = (new Date() - d) / 1000
  if sec < 60 then return Math.round(sec) + "s"
  else if (min = sec / 60) < 60 then return Math.round(min) + "m"
  else if (hr  = min / 60) < 48 then return Math.round(hr) + "h"
  else return Math.round(hr / 24) + "d"

# =================================================================================

getMyKeybaseUsername = (_, cb) ->
  await exec "keybase status -j", defer err, stdout
  try
    status = JSON.parse stdout
  catch err
    console.log err
    console.log stdout
    err = null
  cb err, (status?.Username or "could_not_calc_username")

# =================================================================================

myMostRecentParticipation = (tlfParticipants, username) ->
  for tp in tlfParticipants
    if tp.getWriter() is username
      return tp
  return null

# =================================================================================
# the algorithm
# =================================================================================

main = (_, cb) ->

  esc = make_esc cb, "main"

  await getAllTlfParticipants null, esc defer {tlfs, tlfParticipants}

  # let's sort by time
  tlfParticipants.sort (a,b) -> b.getMTime() - a.getMTime()

  # my last write - let's hold onto this,
  # because we want to make sure that at least one "row" has
  # me as a writer.
  await getMyKeybaseUsername null, esc defer username
  myMostRecent = myMostRecentParticipation(tlfParticipants, username)

  # now let's split into public and private separately so we can guarantee
  # a good mix
  publicTlfQueue = (tp for tp in tlfParticipants when tp.tlf.isPublic())
  privateTlfQueue = (tp for tp in tlfParticipants when not tp.tlf.isPublic())
  console.log "Initially considering #{publicTlfQueue.length} public TLF's, #{privateTlfQueue.length} private TLF's"
  numPublicWanted = Math.max (ROWS_TO_SHOW * TARGET_FRACTION_PUBLIC), (ROWS_TO_SHOW - privateTlfQueue.length)
  publicTlfQueue = publicTlfQueue[...numPublicWanted]
  numPrivateWanted = ROWS_TO_SHOW - publicTlfQueue.length
  privateTlfQueue = privateTlfQueue[0...numPrivateWanted]
  console.log "Now considering #{publicTlfQueue.length} public, #{privateTlfQueue.length} private"


  # ok, let's build the final list, combining:
  #  public TLF participation
  #  private TLF participation
  #  at least one of my own
  rowsToShow = publicTlfQueue.concat privateTlfQueue
  if myMostRecent? and (myMostRecent not in rowsToShow)
    console.log "Pushing self onto queue"
    rowsToShow = rowsToShow[...-1]
    rowsToShow.push myMostRecent

  # finally, sort again by time, since private/public/myMostRecent
  # are coming into this stacked
  rowsToShow.sort (a,b) -> b.getMTime() - a.getMTime()

  console.log "==============================================================="
  console.log "A widget for #{username}"
  console.log "==============================================================="
  for tp in rowsToShow[0...ROWS_TO_SHOW]
    console.log "\n#{tp.writer} - #{timeDisp tp.getMTime()} - #{tp.tlf.path.split(path.sep)[2...].join(path.sep)}"
    for f, i in tp.getLastFiles()
      display_part = f.path.split(path.sep)[-1...][0]
      if (i >= COLLAPSE_AT_PER_ROW) or (tp.getMTime() - f.getMTime() > COLLAPSE_HOURS_PER_ROW * 3600*1000)
        prefix = "     ---collapsed: "
      else
        prefix = ""
      console.log "   #{prefix}#{display_part} (#{timeDisp f.getMTime()})"
  console.log "==============================================================="

# ====================

await main null, defer err
if err? then console.log err
process.exit err?




