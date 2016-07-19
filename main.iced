#!/usr/bin/env iced
fs          = require 'fs'
path        = require 'path'
{make_esc}  = require 'iced-error'
{exec}      = require 'child_process'
iced.catchExceptions (str) -> console.error str


# =================================================================================
#
# This file is an exploration of how to display activity inside KBFS in the widget,
# by not giving too much attention to any one folder. It's inefficient and may cause
# a shitload of tracker popups the first time you run it.
#
# EXPLANATION:
#
#  in widget terms, we bundle into clusters of file activity. Each "cluster" is a bunch
#  of files, all in the same TLF, written by the same writer. So for example, this
#  is a cluster:
#
#      chris  private/chris,strib    4h
#          - shit.txt
#          - foobar.xlsx
#          [+ 10 more]
#
#   The mtime for the cluster, "4h", means the top file in the list was edited 4h ago..
#   the ones below it could go back much further. In this test program, I oucut times next to each
#   file for testing purposes, but we likely won't show them.
#
#
#  BASIC IDEAS:
#
#    - we want final cluster choices sorted by cluster mtimes
#    - we want to make sure the current user has at least one cluster where they're the writer, if possible.
#      This is so they can always find their last edited file in the widget.
#    - we want a controllable ratio of public to private folders, if possible. For example, if we set the ratio
#      TARGET_FRACTION_PUBLIC=0.5, then that means approximately half the clusters will be the 10 most recently
#      modified public folders, and half will be the 10 most recently modified private folders. If the user only has private
#      or only public folder acticity, it should still fill up to the target number of clusters, and this ratio can be broken.
#    - there are a number of file types and directory types we wish to avoid, even though they exist inside KBFS. .DS_Store, temp_file.txt~, etc. Those
#      are controlled by a regexp here, and we may want to expand that list in the future.
#    - in the demo we collapse older stuff in a cluster based on (a) not wanting to show too much in a cluster, and (b) not wanting stuff a lot older than the mtime of the folder
#      ...this collapsing logic may need some work (or may get dropped entirely), so it might make sense to pass this side off to the electron side, and just make sure you get
#      MAX_ACTIVITY_PER_CLUSTER and include mtimes for each file...and let electron figure it out.
#
# CORNER CUTTING:
#
#   In my demo, I actually can't tell who the last editor of a file was, which is crucial info,
#   so I pick randomly based on the writers of a folder.
#
#  LONGER_TERM CONSIDERATIONS:
#
#   - it would be nice to include files that were recently written but are still async-uploading. If that's the case, it would be nice
#     to include basic info on the upload, so that can be shown in the row (uploading...30sec remaining). The logic on that would have to be pretty smart: i
#     if there are 500 files in a cluster's async upload queue, you'd want to include in the list the one(s) that are specifically currently getting sent
#
#   - if this is all tracked through some sort of journaling, we need to make sure we track enough data that a big delete doesn't
#     clear out the widget. (i.e., we want to know the last 20 files edited in a cluster that still exist. So if someone writes 20 files and then deletes them, the
#     previous 20 files should be available still for the widget)
#
#   - there may be synergies here with:
#     - someday making decisions about prefetching
#     - someday showing more stuff in Finder/Explorer about which TLF's have contents?
#
#
# =================================================================================




##=======================================================================

TEST_TLF_LIMIT               = Infinity # crank to low val (10) for faster incomplete results
MAX_CLUSTERS_TO_SHOW         = 20   # how many "clusters" show up in the widget
MAX_ACTIVITY_PER_CLUSTER     = 20   # max files inside a cluster (some can be inside "show more")
COLLAPSE_AT_PER_CLUSTER      = 5    # items after this number are collapsed
COLLAPSE_HOURS_PER_CLUSTER   = 24*7 # items this many hours older than cluster's mtime are collapsed
TARGET_FRACTION_PUBLIC       = 0.5  # try to get approx this frac clusters public
IGNORE_FILES_DATED_IN_FUTURE = true # there are files in my KBFS from 2185 A.D.
TLFS_TO_EXCLUDE_IN_TESTING   = [    # e.g., "/keybase/private/foo" if you want to exclude that from test res
]

#
# The following regexps should probably be expanded upon and not just used by the widget, but
# also by notifications.
#
IGNORE_REGEXP =
  ///
     ( .git\/ )        # anything in a .git directory isn't worth displaying
   | (thumbs\.db$)     # some common OS files and temp files...
   | (desktop\.ini$)   #  windows junk
   | (Icon\r$)         #  windows or OSX junk, I forget
   | (~$)              #  some_temp_file~
   | (\#[^\/]*\#$)     #  #some_temp_file#
   | (.DS_Store$)      #  OSX common file
   | ( \/\._ )         #  OSX extended attribute ._files
   | (.keybasa\/)      #  anything else to exclude?
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
    @clusters = {}

  isPublic: -> ! @path.match /^\/keybase\/private\//

  getWriters: -> @path.split(path.sep)[3].split("#")[0].split(",")

  getClusters: -> (v for k,v of @clusters)

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
      @clusters[writer] or= new Cluster ({tlf: @, writer})
      @clusters[writer].noteFile {file}


# =================================================================================

class Cluster

  constructor: ({@tlf, @writer}) ->
    @lastFiles   = []

  noteFile: ({file}) ->
    # effective for test but inefficient; let's just push and sort each time
    @lastFiles.push file
    @lastFiles.sort (a,b) -> b.stat.mtime - a.stat.mtime
    @lastFiles = @lastFiles[...MAX_ACTIVITY_PER_CLUSTER]

  getLastFiles: -> @lastFiles

  getWriter: -> @writer

  getMTime: -> @lastFiles[0].stat.mtime

# =================================================================================
# =================================================================================
# =================================================================================

getAllClusters = (_, cb) ->
  ###
  This function traverses all TLF's on your computer
  and returns all Cluster instances
  ###
  esc = make_esc cb, "getAllClusters"
  tlfs = []
  clusters = []
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
        clusters = clusters.concat tlf.getClusters()

  cb null, {tlfs, clusters}

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

myMostRecentCluster = (clusters, username) ->
  for c in clusters
    if c.getWriter() is username
      return c
  return null

# =================================================================================
# the algorithm
# =================================================================================

main = (_, cb) ->

  esc = make_esc cb, "main"

  await getAllClusters null, esc defer {tlfs, clusters}

  # let's sort by time
  clusters.sort (a,b) -> b.getMTime() - a.getMTime()

  # my last write - let's hold onto this,
  # because we want to make sure that at least one cluster has
  # me as a writer.
  await getMyKeybaseUsername null, esc defer username
  myMostRecent = myMostRecentCluster(clusters, username)

  # now let's split into public and private separately so we can guarantee
  # a good mix...this mehto
  publicClusters  = (c for c in clusters when c.tlf.isPublic())
  privateClusters = (c for c in clusters when not c.tlf.isPublic())
  console.log "Initially considering #{publicClusters.length} public clusters, #{privateClusters.length} private clusters"
  numPublicWanted = Math.max (MAX_CLUSTERS_TO_SHOW * TARGET_FRACTION_PUBLIC), (MAX_CLUSTERS_TO_SHOW - privateClusters.length)
  publicClusters = publicClusters[...numPublicWanted]
  numPrivateWanted = MAX_CLUSTERS_TO_SHOW - publicClusters.length
  privateClusters = privateClusters[0...numPrivateWanted]
  console.log "Now considering #{publicClusters.length} public, #{privateClusters.length} private"

  # ok, let's build the final list, combining:
  #  public TLF participation
  #  private TLF participation
  #  at least one of my own
  clustersToShow = publicClusters.concat privateClusters
  if myMostRecent? and (myMostRecent not in clustersToShow)
    console.log "Pushing self onto queue"
    clustersToShow = clustersToShow[...-1]
    clustersToShow.push myMostRecent

  # finally, sort again by time, since private/public/myMostRecent
  # are coming into this stacked
  clustersToShow.sort (a,b) -> b.getMTime() - a.getMTime()

  console.log "==============================================================="
  console.log "A widget for #{username}"
  console.log "==============================================================="
  for c in clustersToShow[0...MAX_CLUSTERS_TO_SHOW]
    console.log "\n#{c.writer} - #{timeDisp c.getMTime()} - #{c.tlf.path.split(path.sep)[2...].join(path.sep)}"
    for f, i in c.getLastFiles()
      display_part = f.path.split(path.sep)[-1...][0]
      if (i >= COLLAPSE_AT_PER_CLUSTER) or (c.getMTime() - f.getMTime() > COLLAPSE_HOURS_PER_CLUSTER * 3600*1000)
        prefix = "     ---collapsed: "
      else
        prefix = ""
      console.log "   #{prefix}#{display_part} (#{timeDisp f.getMTime()})"
  console.log "==============================================================="

# ====================

await main null, defer err
if err? then console.log err
process.exit err?




