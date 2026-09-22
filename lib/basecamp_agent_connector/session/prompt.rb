# What a dispatched session is told.
#
# Two prompts, because a session is only briefed once. The first carries
# everything about the task and how to behave; every later comment on the same
# card is just the comment, because the session already knows the rest — which
# is the whole reason for keeping one session per thing of work.
#
# The instruction that matters most is the one about needing input. A session
# that stops to ask the user a question waits forever: nobody is watching its
# terminal, and its state is not something the connector can read back — the
# CLI's session log is raw terminal output, not text. So a session must never
# park itself on a question. It asks in Basecamp, where the requester already
# is, and ends its turn; the answer comes back as a comment on the same
# recording, which routes into this very session and continues it.
class BasecampAgentConnector::Session::Prompt
  # The mention attachment that triggered this. Left in and the agent would
  # read its own name as part of the instruction; stripped, what remains is
  # what was actually asked.
  MENTION_ATTACHMENT = /<bc-attachment\b[^>]*content-type="application\/vnd\.basecamp\.mention"[^>]*>.*?<\/bc-attachment>/m

  def self.opening(event:, agent:, key:, requester:, acked:)
    new(event: event, agent: agent, key: key, requester: requester, acked: acked).opening
  end

  def self.follow_up(event:, requester:)
    new(event: event, agent: nil, key: nil, requester: requester, acked: true).follow_up
  end

  def initialize(event:, agent:, key:, requester:, acked:)
    @event = event
    @agent = agent
    @key = key
    @requester = requester
    @acked = acked
  end

  def opening
    <<~PROMPT
      You are the Basecamp user @#{@agent}, working a task that was assigned to you in Basecamp.
      Everything you post to Basecamp goes through the `basecamp` CLI with `--profile #{@agent}`,
      which is what makes it post as you. Never put "@#{@agent}" in anything you write.

      ## The task

      This session belongs to one thing of work and stays with it: #{@key.type} #{@key.id}, "#{@key.display_name}",
      in the Basecamp project "#{project_name}" (bucket #{@key.bucket_id}). Later comments on it arrive
      as new messages in this same session, so what you learn now is worth keeping in mind.

      Triggered by: #{@event["kind"]}#{trigger_note}
      Requested by: #{@requester}
      The recording that triggered it: #{recording_app_url}
      Reply to: #{reply_target}

      What was asked:

      #{instruction}

      ## Do this, in order

      1. Gather context from Basecamp before acting. The event is a pointer, not the whole story:
         `basecamp show #{recording_app_url} -j` and the thing it hangs off, plus the thread's
         other comments as needed.
      2. Read the project's `AGENTS.md` doc if it has one, and respect it — it is the standing
         instruction file for agents in this project (board and column semantics, comms norms,
         the workflow to run):
         `basecamp docs documents list --all --project #{@key.bucket_id} -j` then
         `basecamp docs show <doc-id> --project #{@key.bucket_id} -j`.
      3. If the work lives on a card sitting in a Triage-like column, and the card table has an
         In progress-like one, move it there first so the board shows the work is underway:
         `basecamp cards columns --project #{@key.bucket_id}` then
         `basecamp cards move <card-id> --to "<In progress>" --profile #{@agent}`.
         Skip it silently if there is no such column — never invent one.
      4. Do the work.#{ack_note}
      5. Reply on the recording as yourself:
         `basecamp comments create #{reply_target} "<body>" --profile #{@agent}`
         Write it as rich text (HTML: <div>, <p>, <strong>, <ul>/<li>, <pre>). If you failed or
         could not finish, say so plainly and @mention #{@requester} so it reaches them.

      ## If the work involves changing code

      Use the EnterWorktree tool before you edit anything, so this task's changes are isolated from
      the other sessions working other cards in the same repo. Commit when you are done, push, and
      open a pull request; put the PR link in your Basecamp reply. Do not push to main and do not
      merge.

      ## If you need something from a person

      Do not stop and wait — nobody is watching this session's terminal, and a session parked on a
      question is indistinguishable from one that died. Instead, post the question as a Basecamp
      comment on the recording, @mentioning #{@requester}, and then end your turn. Their answer will
      arrive as a new message in this session and you can pick up exactly where you left off.

      The same goes for anything you would otherwise assume: ask in Basecamp, end the turn, wait to
      be resumed. That is not a failure — it is how this works.
    PROMPT
  end

  def follow_up
    <<~PROMPT
      New activity in Basecamp on the same thing of work, from #{@requester}:

      #{instruction}

      Posted on: #{recording_app_url}
      Reply to: #{reply_target}

      Pick up from what you already know. Gather any further context you need from Basecamp, do the
      work, and reply on the recording as before. If you need something from a person, post the
      question as a Basecamp comment @mentioning #{@requester} and end your turn rather than waiting.
    PROMPT
  end

  private
    def recording
      @event["recording"] || {}
    end

    def project_name
      recording.dig("bucket", "name")
    end

    def recording_app_url
      recording["app_url"] || recording["url"]
    end

    # Basecamp has no comment-on-a-comment: `comments create` only takes a
    # commentable parent, so a mention that arrived inside a comment is
    # answered on the card/message that comment lives on. Pointing it at the
    # comment itself fails with `access denied`.
    def reply_target
      if recording["type"] == "Comment"
        recording.dig("parent", "app_url") || recording.dig("parent", "url") || recording_app_url
      else
        recording_app_url
      end
    end

    # A boost carries no content of its own on the recording — the reaction is
    # in `details`. An assignment's instruction is the recording's own title
    # and body.
    def instruction
      body = @event.dig("details", "boost", "content") if @event["kind"] == "boost_created"
      body ||= recording["content"]
      body = [ recording["title"], body ].compact.join("\n\n") if body.to_s.strip.empty? || assignment?

      body.to_s.gsub(MENTION_ATTACHMENT, "").strip
    end

    def assignment?
      @event["kind"].to_s.include?("assignment")
    end

    def trigger_note
      return " (you were @mentioned)" if @event.dig("trigger", "mentioned")
      return " (a comment on a thread you follow — context, not necessarily a directive)" if @event.dig("trigger", "subscribed")

      ""
    end

    def ack_note
      return "" if @acked

      "\n   The receipt boost could not be posted, so post one first: " \
        "`basecamp boost create #{recording["url"]} \"<short ack>\" --profile #{@agent}`."
    end
end
