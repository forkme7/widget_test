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

TEST_TLF_LIMIT               = 20 # crank to low val (10) for faster incomplete results
ROWS_TO_SHOW                 = 10
MAX_ACTIVITY_PER_ROW         = 20
COLLAPSE_AT_PER_ROW          = 5  # items after this number are collapsed
COLLAPSE_HOURS_PER_ROW       = 12 # items this many hours older than first item in row are collapsed
TARGET_FRACTION_PUBLIC       = 0.5  # try to get approx this many rows public
IGNORE_FILES_DATED_IN_FUTURE = true # there are files in my KBFS from 2185 A.D.
TLFS_TO_EXCLUDE_IN_TESTING   = [    # e.g., "/keybase/private/foo" if you want to exclude that from test res
]
IGNORE_REGEXP =
  ///
     ( .git\/ )     # anything in a .git directory
   | ( \/\._ )         # ._FILES made in OSX
   | (thumbs\.db$)     # some common OS files and temp files...
   | (desktop\.ini$)
   | (~$)
   | (Icon\r$)
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
    @tlf_participants = {}

  isPublic: ->
    ! @path.match /^\/keybase\/private\//

  getWriters: -> @path.split(path.sep)[3].split("#")[0].split(",")

  getTlfParticipants: -> (v for k,v of @tlf_participants)

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
      @tlf_participants[writer] or= new TlfParticipant ({tlf: @, writer})
      @tlf_participants[writer].noteFile {file}


# =================================================================================

class TlfParticipant
  # This corresponds to one person crossed with their recent write activity
  # in a TLF.
  constructor: ({@tlf, @writer}) ->
    @last_files   = []

  noteFile: ({file}) ->
    @last_files.push file
    # obviously faster way of keeping latest N when it matters
    @last_files.sort (a,b) -> b.stat.mtime - a.stat.mtime
    if @last_files.length > MAX_ACTIVITY_PER_ROW
      @last_files = @last_files[...MAX_ACTIVITY_PER_ROW]

  getLastFiles: -> @last_files

  getWriter: -> @writer

  getMTime: -> @last_files[0].stat.mtime

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
  tlf_participants = []
  for dir in ["/keybase/private", "/keybase/public"]
    await fs.readdir dir, esc defer tlf_names
    tlf_names = (tlf_name for tlf_name in tlf_names when path.join(dir,tlf_name) not in TLFS_TO_EXCLUDE_IN_TESTING)
    for tlf_name in tlf_names[...TEST_TLF_LIMIT]
      tlf = new Tlf {path: path.join(dir, tlf_name)}
      await tlf.hunt null, defer err
      if err
        console.error err
      else
        tlfs.push tlf
        tlf_participants = tlf_participants.concat tlf.getTlfParticipants()

  cb null, {tlfs, tlf_participants}

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

myMostRecentParticipation = (tlf_participants, username) ->
  for tp in tlf_participants
    if tp.getWriter() is username
      return tp
  return null

# =================================================================================
# the algorithm
# =================================================================================

main = (_, cb) ->

  esc = make_esc cb, "main"

  await getAllTlfParticipants null, esc defer {tlfs, tlf_participants}

  # let's sort by time
  tlf_participants.sort (a,b) -> b.getMTime() - a.getMTime()

  # my last write - let's hold onto this
  await getMyKeybaseUsername null, esc defer username
  my_most_recent = myMostRecentParticipation(tlf_participants, username)

  # now let's split into public and private separately so we can guarantee
  # a good mix
  public_tlf_queue = (tp for tp in tlf_participants when tp.tlf.isPublic())
  private_tlf_queue = (tp for tp in tlf_participants when not tp.tlf.isPublic())
  console.log "Initially considering #{public_tlf_queue.length} public, #{private_tlf_queue.length} private"
  num_public_wanted = Math.max (ROWS_TO_SHOW * TARGET_FRACTION_PUBLIC), (ROWS_TO_SHOW - private_tlf_queue.length)
  public_tlf_queue = public_tlf_queue[...num_public_wanted]
  num_private_wanted = ROWS_TO_SHOW - public_tlf_queue.length
  private_tlf_queue = private_tlf_queue[0...num_private_wanted]
  console.log "Now considering #{public_tlf_queue.length} public, #{private_tlf_queue.length} private"

  final_candidates = public_tlf_queue.concat private_tlf_queue


  # make sure my last write is in there
  if my_most_recent? and (my_most_recent not in final_candidates)
    console.log "Pushing self onto queue"
    final_candidates = final_candidates[...-1]
    final_candidates.push my_most_recent

  # finally, sort again by time, since private/public are stacked
  final_candidates.sort (a,b) -> b.getMTime() - a.getMTime()

  console.log "==============================================================="
  console.log "A widget for #{username}"
  console.log "==============================================================="
  for tp in final_candidates[0...ROWS_TO_SHOW]
    # there are some files in my dir from 2185!
    console.log "\n#{tp.writer} - #{timeDisp tp.getMTime()} - #{tp.tlf.path.split(path.sep)[2...].join(path.sep)}"
    for f, i in tp.getLastFiles()
      display_part = f.path.split(path.sep)[-1...][0]
      if (i >= COLLAPSE_AT_PER_ROW) or (tp.getMTime() - f.getMTime() > COLLAPSE_HOURS_PER_ROW * 3600*1000)
        collapse_prefix = "     ---collapsed: "
        collapse_suffix = " (#{timeDisp f.getMTime()})"
      else
        collapse_suffix = " (#{timeDisp f.getMTime()})"
        collapse_prefix = ""
      console.log "   #{collapse_prefix}#{display_part}#{collapse_suffix}"
  console.log "==============================================================="

# ====================

await main null, defer err
if err? then console.log err
process.exit err?




