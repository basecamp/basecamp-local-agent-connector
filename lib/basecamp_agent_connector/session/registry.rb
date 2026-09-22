require "json"
require "fileutils"
require "time"

# Which Claude session owns which thing of work, and what is waiting to be said
# to it.
#
# This is the state that makes a session a *thread*. Without it every event
# would open a new session and the connector would be back to re-reading a card
# from scratch each time somebody comments on it. It is deliberately modelled on
# RunRegistry, which solves the same shape of problem one level up: a durable
# record per live thing, an atomic rename so a concurrent reader never sees half
# a file, and a lock so two events arriving together cannot both decide they are
# the first.
#
# That lock is not theoretical here. Webhook deliveries are handled on their own
# threads, and two comments posted a second apart on the same card race
# each other to the same decision — "is there a session for this yet?" Both
# reading "no" means two sessions for one card, which is precisely the state
# this class exists to prevent, so the read and the write that follows it happen
# under one per-key lock.
class BasecampAgentConnector::Session::Registry
  DEFAULT_DIRECTORY = File.expand_path("~/.config/basecamp-connect/sessions")

  # An entry names a session that can be resumed and a repo it runs in. Neither
  # is anyone else's business.
  DIRECTORY_MODE = 0o700
  ENTRY_MODE = 0o600

  class Error < StandardError; end

  # Both ids are stored rather than one derived from the other. The short id is
  # what `claude stop` takes and what the spawn prints; the full uuid is what
  # `--resume` requires, and is looked up afterwards — a lookup that can fail,
  # leaving a session that runs and replies but cannot yet be continued.
  # Deriving the short id from the uuid would make that entry unrecordable.
  Entry = Data.define(:key, :session_id, :short_id, :name, :repo, :created_at, :queue) do
    def self.from_json(json)
      new(key: json["key"], session_id: json["session_id"], short_id: json["short_id"],
        name: json["name"], repo: json["repo"], created_at: json["created_at"], queue: Array(json["queue"]))
    end

    # Whether this session can be continued in place. Without the full uuid,
    # `--resume` would fork a copy and the card would have two sessions.
    def resumable?
      !session_id.nil? && !session_id.empty?
    end

    def to_json(*arguments)
      JSON.generate({ key: key, session_id: session_id, short_id: short_id, name: name, repo: repo,
        created_at: created_at, queue: queue }, *arguments)
    end
  end

  def initialize(directory: DEFAULT_DIRECTORY)
    @directory = directory
  end

  # Runs the block holding this key's lock, handing it the current entry (or
  # nil) and writing back whatever it returns. Returning nil leaves the entry
  # untouched; returning :forget deletes it.
  #
  # Every decision about a key goes through here, so that deciding and
  # recording cannot be separated by another thread's decision.
  def with(key)
    exclusively(key) do
      entry = read(file_for(key))
      result = yield entry

      case result
      when nil then entry
      when :forget then remove(file_for(key)) and nil
      else write(file_for(key), result) and result
      end
    end
  end

  def find(key)
    read file_for(key)
  end

  # Holds a message for a session that is busy. Appending under the lock, and
  # re-reading inside it, is what keeps two comments arriving together from
  # each writing a queue containing only itself.
  def enqueue(key, message)
    with(key) do |entry|
      next nil if entry.nil?

      entry.with(queue: entry.queue + [ message ])
    end
  end

  # Takes everything waiting and clears it in one step, so a flush that starts
  # while a new comment lands cannot swallow the comment without delivering it.
  def drain(key)
    taken = []

    with(key) do |entry|
      next nil if entry.nil? || entry.queue.empty?

      taken = entry.queue
      entry.with(queue: [])
    end

    taken
  end

  def all
    Dir.glob(File.join(@directory, "*.json")).filter_map { |file| read(file) }
  end

  def queued
    all.reject { |entry| entry.queue.empty? }
  end

  def forget(key)
    with(key) { :forget }
  end

  private
    def read(file)
      Entry.from_json(JSON.parse(File.read(file)))
    rescue JSON::ParserError, SystemCallError, TypeError
      # An unreadable or half-written entry says nothing. Leaving it costs one
      # session that gets re-spawned; deleting it could orphan a live one.
      nil
    end

    # Per key rather than one lock for the whole directory: a dispatch holds
    # this across spawning a session, and `claude --bg` takes about a second to
    # return. One global lock would serialize every card's first event behind
    # every other card's.
    def exclusively(key)
      prepare_directory
      File.open(lock_file_for(key), File::RDWR | File::CREAT, ENTRY_MODE) do |lock|
        lock.flock File::LOCK_EX

        begin
          yield
        ensure
          lock.flock File::LOCK_UN
        end
      end
    rescue SystemCallError => error
      raise Error, "could not lock the session registry in #{@directory}: #{error.message}"
    end

    # Written to a neighbouring temporary file and renamed into place, so a
    # concurrent reader sees the old entry or the new one, never half of one.
    # The mode is set at creation rather than left to the umask.
    def write(file, entry)
      temporary = "#{file}.#{Process.pid}.tmp"
      prepare_directory
      File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, ENTRY_MODE) { |handle| handle.write entry.to_json }
      File.rename temporary, file
      true
    rescue SystemCallError => error
      remove temporary
      raise Error, "could not record a session in #{@directory}: #{error.message}"
    end

    def prepare_directory
      FileUtils.mkdir_p @directory, mode: DIRECTORY_MODE
      File.chmod DIRECTORY_MODE, @directory
    end

    def remove(file)
      File.delete file
      true
    rescue SystemCallError
      true
    end

    def file_for(key)
      File.join(@directory, "#{key}.json")
    end

    def lock_file_for(key)
      File.join(@directory, "#{key}.lock")
    end
end
