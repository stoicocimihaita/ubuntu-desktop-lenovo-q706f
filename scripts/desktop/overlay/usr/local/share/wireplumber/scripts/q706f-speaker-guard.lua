local log = Log.open_topic ("s-q706f-speaker-guard")
local hardware = "alsa_output.platform-sound.HiFi__Speaker__sink"

SimpleEventHook {
  name = "linking/q706f-speaker-guard",
  after = "linking/prepare-link",
  before = "linking/link-target",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    local target = event:get_data ("target")
    local stream = event:get_subject ()
    if target and target.properties["node.name"] == hardware and
        stream.properties["item.node.direction"] == "output" and
        stream.properties["node.name"] ~= "q706f_speakers.out" then
      log:warning ("Blocked direct link to internal speakers")
      event:set_data ("target", nil)
    end
  end,
}:register ()
