# The ping source: Basecamp's direct messages, read as a trigger.
#
# It exists because the bridge cannot carry them. Basecamp refuses every chat
# type at webhook registration -- `Chat::Line`, `Chat::Transcript::Line`,
# `Campfire` and the rest all come back `types: must be eligible` -- so a ping
# reaches a local agent by polling or not at all.
#
# Discovery and reading are two different mechanisms here, which is what makes
# this source unlike Poller. A conversation is *found* through the notification
# feed, because nothing indexes pings: `circles.json` answers with an empty
# envelope and they appear in no recording listing. But a conversation is *read*
# through its own lines endpoint, directly, forever after -- and it has to be,
# because the notification is one record per conversation that Basecamp re-marks
# unread as messages arrive. Deduplicating on it would fire on the first ping in a
# thread and swallow every one after it.
class BasecampAgentConnector::Basecamp::Pings
  KIND = "chat_line_created"

  # Both remembered per conversation-and-transcript pair, because a circle id on
  # its own addresses nothing readable.
  CIRCLES = "circles"

  LINES = "ping_lines"

  # Pages are strictly newest-first and never overlap -- measured 2026-08-26 at 15,
  # 30 and 50 lines for pages 1 to 3 -- so walking stops at the first line already
  # seen. The cap bounds what a restart after a long outage will replay; beyond it
  # the older lines are marked seen without emitting, because answering a question
  # from two days ago as though it just arrived is worse than not answering it.
  MAX_PAGES = 3

  def initialize(basecamp_cli:, agent:, operator:, state:, logger: $stderr)
    @basecamp_cli = basecamp_cli
    @agent = agent
    @operator = operator
    @state = state
    @logger = logger
  end

  # Everything the operator has said since the last round, oldest first.
  #
  # Conversations already known are read first, so a circle discovered this round
  # is not also polled this round -- adoption already returned its unread lines,
  # and reading it twice would emit them twice.
  def payloads
    @staged = {}
    @pages = {}
    established = remembered_circles

    adopted = adopt_new_circles
    emitted = established.flat_map { |circle| new_lines(circle) } + adopted
    (established + @adopted_this_round.to_a).each { |circle| reap circle }
    emitted
  end

  # Undo what this round remembered for a payload that was never emitted, so the
  # next round finds the line again. Recording a line id claims the message was
  # handled, and a Basecamp that could not be reached to corroborate it has not
  # handled anything.
  def rollback(payload)
    Array(@staged&.delete(payload.dig("recording", "id"))).each do |source, id|
      state.forget source, id
    end
  end

  # A first run starts from now: every conversation is remembered with every line
  # it currently holds, and nothing is emitted. Without it the bot would answer a
  # month of conversation the moment it was switched on.
  def seed
    ping_circles.each do |circle|
      state.record CIRCLES, circle.key
      fetch_lines(circle, page: 1).each { |line| remember_line line }
    end
  end

  private
    attr_reader :basecamp_cli, :agent, :operator, :state

    def remembered_circles
      state.recorded(CIRCLES).filter_map { |key| BasecampAgentConnector::Basecamp::Circle.from_key(key) }
    end

    # A ping he has boosted is one he has already acted on, so the conversation
    # stops having to carry it. His words on 2026-08-27: "I've taken action and
    # now they're gone so we can keep the ping clean."
    #
    # Narrow on purpose, in three ways. Only the agent's own lines -- his are his
    # to delete. Only a boost from HIM, confirmed by reading the boost rather than
    # trusting the count, because anyone else in a conversation could otherwise
    # delete the bot's side of it. And only page one, because a boost arrives
    # while the message is still recent and scanning the whole history every round
    # would cost a call per line forever.
    #
    # `boosts_count` rides along in the listing already fetched, so a round with
    # no boosts costs nothing extra.
    def reap(circle)
      fetch_lines(circle, page: 1).each do |line|
        next unless agent_authored?(line)
        next unless (line["boosts_count"] || 0).positive?
        next unless boosted_by_operator?(circle, line)

        delete circle, line
      end
    end

    def boosted_by_operator?(circle, line)
      return false if operator.person_id.nil?

      boosts = basecamp_cli.get_listing(circle.boosts_path(line["id"]), profile: agent.profile)
      boosts.any? { |boost| boost.dig("booster", "id") == operator.person_id }
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not read the boosts on ping #{line['id']}: #{error.message}"
      false
    end

    # A failed delete is left alone rather than retried here: the line is still
    # remembered, so nothing re-emits, and the next round sees the boost again.
    def delete(circle, line)
      basecamp_cli.delete circle.line_path(line["id"]), profile: agent.profile
      log "deleted ping #{line['id']}, boosted by the operator"
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not delete ping #{line['id']}: #{error.message}"
    end

    def agent_authored?(line)
      return false if agent.person_id.nil?

      line.dig("creator", "id") == agent.person_id
    end

    # Adoption emits the newest unbroken run of operator-authored lines and marks
    # everything older seen. A conversation opened just now holds exactly the
    # message he wrote, so it fires. One that has been running for months holds his
    # latest message and a history he is not asking about, and replaying that
    # history would dispatch an agent per message.
    def adopt_new_circles
      @adopted_this_round = []

      new_circles.flat_map do |circle|
        state.record CIRCLES, circle.key
        @adopted_this_round << circle
        log "adopted ping conversation #{circle}"

        lines = fetch_lines(circle, page: 1)
        unread = lines.take_while { |line| operator_authored?(line) }
        lines.drop(unread.length).each { |line| remember_line line }

        # Skipping what is already remembered, even here. Adoption is written for a
        # conversation nobody has read, so it consults the head run rather than the
        # line memory -- and that made it the one path that could re-emit a message
        # already dispatched, if a circle key were ever lost while its line ids
        # survived. The two live in the same file and are capped separately, so
        # that is reachable. Nothing is lost by checking: on a genuinely new
        # conversation no line is remembered and the run emits whole.
        unread.reject { |line| seen_line?(line) }
          .reverse.filter_map { |line| emit circle, line }
      end
    end

    def new_circles
      ping_circles.reject { |circle| state.seen?(CIRCLES, circle.key) }
    end

    def ping_circles
      notifications
        .select { |notification| BasecampAgentConnector::Basecamp::Circle.ping?(notification) }
        .filter_map { |notification| BasecampAgentConnector::Basecamp::Circle.from_notification(notification) }
        .uniq
    end

    def new_lines(circle)
      unseen_lines(circle).reverse.filter_map { |line| emit circle, line }
    end

    def unseen_lines(circle)
      collected = []

      (1..MAX_PAGES).each do |page|
        lines = fetch_lines(circle, page: page)
        return collected if lines.empty?

        fresh = lines.take_while { |line| !seen_line?(line) }
        collected.concat fresh
        return collected if fresh.length < lines.length
      end

      collected
    end

    # Every line the round looked at is remembered, emitted or not, or the ones
    # that are never emitted are re-read on every round for as long as the poller
    # runs. The agent's own replies land in the same conversation and are the usual
    # reason a line is passed over here.
    #
    # The operator check is repeated in Pipeline against the corroborated copy.
    # This one only keeps the bot from paying for a verification round on its own
    # messages -- the trust decision is not made here.
    def emit(circle, line)
      remember_line line
      return nil unless operator_authored?(line)

      payload = payload_for(circle, line)
      stage payload, LINES, line["id"]
      payload
    end

    def payload_for(circle, line)
      {
        "id" => line["id"],
        "kind" => KIND,
        "created_at" => line["created_at"],
        "creator" => line["creator"],
        "recording" => line
      }
    end

    def stage(payload, source, id)
      ((@staged ||= {})[payload.dig("recording", "id")] ||= []) << [ source, id ]
      payload
    end

    def operator_authored?(line)
      return false if operator.person_id.nil?

      line.dig("creator", "id") == operator.person_id
    end

    def seen_line?(line)
      line["id"].nil? || state.seen?(LINES, line["id"])
    end

    def remember_line(line)
      state.record LINES, line["id"] unless line["id"].nil?
      nil
    end

    def notifications
      listing = basecamp_cli.notifications(profile: agent.profile)
      Array(listing["unreads"]) + Array(listing["reads"])
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not read notifications for pings: #{error.message}"
      []
    end

    # A failed read is left unremembered so the next round asks again. There is no
    # permanent-absence case to separate out the way a recording read has one: a
    # conversation the agent is no longer part of answers `not_found` forever, and
    # re-asking costs one call a minute against a listing that is never large.
    # Memoized for the round, because the reaper needs the same page the emitter
    # just read and refetching it would double the cost of every round.
    def fetch_lines(circle, page: nil)
      key = [ circle.key, page ]
      cached = (@pages ||= {})
      return cached[key] if cached.key?(key)

      cached[key] = read_lines(circle, page: page)
    end

    def read_lines(circle, page: nil)
      basecamp_cli.get_listing(circle.lines_path(page: page), profile: agent.profile)
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not read ping conversation #{circle}: #{error.message}"
      []
    end

    def log(message)
      @logger.puts message
    end
end
