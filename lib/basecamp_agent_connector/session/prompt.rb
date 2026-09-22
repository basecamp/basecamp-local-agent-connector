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

  # `acked` is false when the receipt boost for this activity did not land, so
  # the session posts it — a follow-up is owed a receipt as much as the first
  # message was.
  def self.follow_up(event:, requester:, agent:, acked: true)
    new(event: event, agent: agent, key: nil, requester: requester, acked: acked).follow_up
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
      3. #{column_step}
      4. Do the work.#{ack_note}
      5. Reply on the recording as yourself:
         `basecamp comments create #{reply_target} "<body>" --profile #{@agent}`
         Write it as rich text (HTML: <div>, <p>, <strong>, <ul>/<li>, <pre>). The body is a
         positional argument and `comments create` reads nothing from stdin, so redirecting a
         file into it (`< reply.html`) prints the command's usage and posts nothing. For a long
         body, write the file and then pass it as that argument:
         `basecamp comments create #{reply_target} "$(cat reply.html)" --profile #{@agent}`
         If you failed or could not finish, say so plainly and @mention #{@requester} so it
         reaches them.

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

      Pick up from what you already know.#{" #{receipt_instruction}" unless @acked} Gather any further
      context you need from Basecamp, do the work, and reply on the recording as before. If you need
      something from a person, post the question as a Basecamp comment @mentioning #{@requester} and
      end your turn rather than waiting.
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
      return moved_instruction if moved?

      body = @event.dig("details", "boost", "content") if @event["kind"] == "boost_created"
      body ||= recording["content"]
      body = [ recording["title"], body ].compact.join("\n\n") if body.to_s.strip.empty? || assignment?

      body.to_s.gsub(MENTION_ATTACHMENT, "").strip
    end

    # A move carries no words, so the card's own description must not be handed
    # over as though it were newly said — on a follow-up that would read as the
    # requester repeating the brief, and the agent would redo work it had
    # already done. What was asked is the move itself, and the column names the
    # work: the project's AGENTS.md is where that column's meaning is written
    # down, which is why this points at it rather than guessing at semantics
    # the board's owner has already defined.
    def moved_instruction
      <<~MOVED.strip
        This card was moved into the "#{column_title}" column#{" by #{@requester}" unless @requester.nil?}.

        No message came with it — the move is the request. On this board the column says what kind of
        work is wanted, so read the project's AGENTS.md for what "#{column_title}" means here and do
        that. If it says this column is not a request for work, do nothing and say nothing.
      MOVED
    end

    def moved?
      @event.dig("trigger", "moved") == true
    end

    # Moving the card out of where it sits is right when the agent picked the
    # work up itself, and wrong when a person just put it there: the column
    # they chose is the instruction, and shunting it elsewhere both overrides
    # them and erases the signal.
    def column_step
      if moved?
        <<~STEP.strip
          Leave the card where it is. #{@requester} put it in "#{column_title}" deliberately, and that
             column is the request — move it on only when the work the column asks for is finished and
             AGENTS.md says where it goes next.
        STEP
      else
        <<~STEP.strip
          If the work lives on a card sitting in a Triage-like column, and the card table has an
             In progress-like one, move it there first so the board shows the work is underway:
             `basecamp cards columns --project #{@key.bucket_id}` then
             `basecamp cards move <card-id> --to "<In progress>" --profile #{@agent}`.
             Skip it silently if there is no such column — never invent one.
        STEP
      end
    end

    def column_title
      recording.dig("parent", "title")
    end

    def assignment?
      @event["kind"].to_s.include?("assignment")
    end

    def trigger_note
      return " (you were @mentioned)" if @event.dig("trigger", "mentioned")
      return " (the card was moved into \"#{column_title}\")" if moved?
      return " (a comment on a thread you follow — context, not necessarily a directive)" if @event.dig("trigger", "subscribed")

      ""
    end

    def ack_note
      return "" if @acked

      "\n   #{receipt_instruction}"
    end

    def receipt_instruction
      "The receipt boost could not be posted, so post one first: `#{receipt_command}`."
    end

    # The same receipt the dispatcher would have posted: on a move, the
    # adoption event in the card's history rather than the card, so it says
    # which move was picked up.
    def receipt_command
      event_flag = " --event #{@event["event_id"]}" if moved? && @event["event_id"]

      "basecamp boost create #{recording["url"]} \"<short ack>\"#{event_flag} --profile #{@agent}"
    end
end
