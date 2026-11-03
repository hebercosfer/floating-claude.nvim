-- Hook events as Claude Code 2.1.317 posted them, captured in the spike of
-- 2026-11-03 (docs/superpowers/specs/2026-11-03-hooks-listener-design.md).
-- Ids, paths and the user name are scrubbed and tool output is cut to 200
-- bytes; everything else -- unsubscribed events, subagent events, order and
-- arrival times in ms -- is as it arrived. `permission` is written by hand
-- from the first spike's Bash permission, whose log did not survive.

return {
  background_task = {
    {
      at = 163868,
      event = {
        cwd = "/project",
        hook_event_name = "UserPromptSubmit",
        permission_mode = "default",
        prompt = "Run `sleep 30` with the Bash tool, then say done.",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 165042,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolBatch",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_calls = {
          {
            tool_input = {
              command = "sleep 30",
              description = "Pause for 30 seconds",
            },
            tool_name = "Bash",
            tool_response = "<tool_use_error>Blocked: standalone sleep 30. To wait for a condition, use Monitor with an until-loop (e.g. `until <check>; do sleep 2; done`). To wait for a command you started, use run_in_background",
            tool_use_id = "id",
          },
        },
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 167868,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PreToolUse",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          command = "sleep 30",
          description = "Run sleep 30 in background",
          run_in_background = true,
        },
        tool_name = "Bash",
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 167885,
      event = {
        cwd = "/project",
        delta = "The shell blocked a standalone `sleep` in the foreground, so I'll run it in the background, which the block message suggests for waiting on a command.",
        final = true,
        hook_event_name = "MessageDisplay",
        index = 0,
        message_id = "id",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
        turn_id = "id",
      },
    },
    {
      at = 167912,
      event = {
        cwd = "/project",
        duration_ms = 18,
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolUse",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          command = "sleep 30",
          description = "Run sleep 30 in background",
          run_in_background = true,
        },
        tool_name = "Bash",
        tool_response = {
          backgroundTaskId = "bw686dv5b",
          interrupted = false,
          isImage = false,
          noOutputExpected = false,
          stderr = "",
          stdout = "",
        },
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 167927,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolBatch",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_calls = {
          {
            tool_input = {
              command = "sleep 30",
              description = "Run sleep 30 in background",
              run_in_background = true,
            },
            tool_name = "Bash",
            tool_response = "Command running in background with ID: bw686dv5b. Output is being written to: /tmp/claude/task.output You will be notified when it completes — do not poll that file or sleep while waiting. Read the ",
            tool_use_id = "id",
          },
        },
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 168866,
      event = {
        background_tasks = {
          {
            command = "sleep 30",
            description = "Run sleep 30 in background",
            id = "bw686dv5b",
            status = "running",
            type = "shell",
          },
        },
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "Stop",
        last_assistant_message = "The foreground `sleep 30` was blocked by the shell, so I started it in the background instead. It will finish in about 30 seconds, and I'll confirm once it does.",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_crons = {},
        session_id = "id",
        stop_hook_active = false,
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 168866,
      event = {
        cwd = "/project",
        delta = "The foreground `sleep 30` was blocked by the shell, so I started it in the background instead. It will finish in about 30 seconds, and I'll confirm once it does.",
        final = true,
        hook_event_name = "MessageDisplay",
        index = 0,
        message_id = "id",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
        turn_id = "id",
      },
    },
    {
      at = 170405,
      event = {
        agent_id = "id",
        agent_transcript_path = "/project/t.jsonl",
        agent_type = "",
        background_tasks = {
          {
            command = "sleep 30",
            description = "Run sleep 30 in background",
            id = "bw686dv5b",
            status = "running",
            type = "shell",
          },
        },
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "SubagentStop",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_crons = {},
        session_id = "id",
        stop_hook_active = false,
        transcript_path = "/project/t.jsonl",
      },
    },
  },
  interrupt_mid_reply = {
    {
      at = 57063,
      event = {
        cwd = "/project",
        hook_event_name = "UserPromptSubmit",
        permission_mode = "default",
        prompt = "Write a 500-word story about a lighthouse keeper, in plain paragraphs.",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 58532,
      event = {
        cwd = "/project",
        delta = "The lighthouse stood on a finger of black rock at the end of Marrow Point, and for thirty-one years Edwin Calloway climbed its one hundred and twelve iron steps every evening before sunset. He carried a tin of paraffin, a rag, and a small brass key that he never let leave his coat pocket.\n\n",
        final = false,
        hook_event_name = "MessageDisplay",
        index = 0,
        message_id = "id",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
        turn_id = "id",
      },
    },
  },
  interrupted_tool = {
    {
      at = 187937,
      event = {
        cwd = "/project",
        hook_event_name = "UserPromptSubmit",
        permission_mode = "default",
        prompt = "Run exactly this in the foreground with the Bash tool, not in the background: for i in 1 2 3 4 5 6 7 8 9 10; do date; sleep 3; done",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 190910,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PreToolUse",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          command = "for i in 1 2 3 4 5 6 7 8 9 10; do date; sleep 3; done",
          description = "Print date and sleep 3 seconds, ten times, in foreground",
        },
        tool_name = "Bash",
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 197948,
      event = {
        cwd = "/project",
        hook_event_name = "UserPromptSubmit",
        permission_mode = "default",
        prompt = '<task-notification>\n<task-id>bw686dv5b</task-id>\n<tool-use-id>toolu_01FxNijwJRdxDbYBsBZto72i</tool-use-id>\n<output-file>/tmp/claude/task.output</output-file>\n<status>completed</status>\n<summary>Background command "Run sleep 30 in background" completed (exit code 0)</summary>\n</task-notification>',
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 199519,
      event = {
        background_tasks = {},
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "Stop",
        last_assistant_message = "The background `sleep 30` finished with exit code 0. Your interrupt stopped the foreground loop, so I haven't run it. Do you want me to try it again, or leave it there?",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_crons = {},
        session_id = "id",
        stop_hook_active = false,
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 199519,
      event = {
        cwd = "/project",
        delta = "The background `sleep 30` finished with exit code 0. Your interrupt stopped the foreground loop, so I haven't run it. Do you want me to try it again, or leave it there?",
        final = true,
        hook_event_name = "MessageDisplay",
        index = 0,
        message_id = "id",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
        turn_id = "id",
      },
    },
    {
      at = 200579,
      event = {
        agent_id = "id",
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PreToolUse",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          command = "for i in 1 2 3 4 5 6 7 8 9 10; do date; sleep 3; done",
          description = "Print date and sleep 3 seconds, ten times, in foreground",
        },
        tool_name = "Bash",
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 200585,
      event = {
        agent_id = "id",
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolBatch",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_calls = {
          {
            tool_input = {
              command = "for i in 1 2 3 4 5 6 7 8 9 10; do date; sleep 3; done",
              description = "Print date and sleep 3 seconds, ten times, in foreground",
            },
            tool_name = "Bash",
            tool_response = "No tools needed for suggestion",
            tool_use_id = "id",
          },
        },
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 201465,
      event = {
        agent_id = "id",
        agent_transcript_path = "/project/t.jsonl",
        agent_type = "",
        background_tasks = {},
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "SubagentStop",
        last_assistant_message = "run the loop again",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_crons = {},
        session_id = "id",
        stop_hook_active = false,
        transcript_path = "/project/t.jsonl",
      },
    },
  },
  permission = {
    {
      at = 1000,
      event = {
        hook_event_name = "UserPromptSubmit",
        prompt = "Run printf",
      },
    },
    {
      at = 2000,
      event = {
        hook_event_name = "PreToolUse",
        tool_input = {
          command = "printf again > spike2.txt",
          description = 'Write "again" to spike2.txt',
        },
        tool_name = "Bash",
      },
    },
    {
      at = 2030,
      event = {
        hook_event_name = "PermissionRequest",
        tool_input = {
          command = "printf again > spike2.txt",
          description = 'Write "again" to spike2.txt',
        },
        tool_name = "Bash",
      },
    },
    {
      at = 9000,
      event = {
        hook_event_name = "PostToolUse",
        tool_input = {
          command = "printf again > spike2.txt",
          description = 'Write "again" to spike2.txt',
        },
        tool_name = "Bash",
        tool_response = {
          stderr = "",
          stdout = "",
        },
      },
    },
    {
      at = 9500,
      event = {
        hook_event_name = "Stop",
        last_assistant_message = "Done.",
      },
    },
  },
  plan = {
    {
      at = 220024,
      event = {
        cwd = "/project",
        hook_event_name = "UserPromptSubmit",
        permission_mode = "plan",
        prompt = "Plan how to create a file hello.txt containing the word hi. Keep the plan to two steps, then present it for approval.",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 224259,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PreToolUse",
        permission_mode = "plan",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          content = '# Plan: create hello.txt containing "hi"\n\n## Context\nThe user wants a file `hello.txt` containing the word "hi". The working directory (`/home/user/.cache/project/proj`) is empty and not a git repo, so there is nothing to reuse and no commit is involved.\n\n## Steps\n1. Create `/home/user/.cache/project/proj/hello.txt` with the content `hi` (single line, trailing newline) using the Write tool.\n2. Verify by reading the file back (or `cat hello.txt`) and confirming it contains exactly `hi`.\n\n## Verification\n`cat hello.txt` prints `hi`.\n',
          file_path = "/home/user/.claude/plans/plan-how-to-create-compressed-mountain.md",
        },
        tool_name = "Write",
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 224295,
      event = {
        cwd = "/project",
        duration_ms = 25,
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolUse",
        permission_mode = "plan",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          content = '# Plan: create hello.txt containing "hi"\n\n## Context\nThe user wants a file `hello.txt` containing the word "hi". The working directory (`/home/user/.cache/project/proj`) is empty and not a git repo, so there is nothing to reuse and no commit is involved.\n\n## Steps\n1. Create `/home/user/.cache/project/proj/hello.txt` with the content `hi` (single line, trailing newline) using the Write tool.\n2. Verify by reading the file back (or `cat hello.txt`) and confirming it contains exactly `hi`.\n\n## Verification\n`cat hello.txt` prints `hi`.\n',
          file_path = "/home/user/.claude/plans/plan-how-to-create-compressed-mountain.md",
        },
        tool_name = "Write",
        tool_response = {
          content = '# Plan: create hello.txt containing "hi"\n\n## Context\nThe user wants a file `hello.txt` containing the word "hi". The working directory (`/home/user/.cache/project/proj`) is empty and not a git repo, s',
          filePath = "/home/user/.claude/plans/plan-how-to-create-compressed-mountain.md",
          originalFile = vim.NIL,
          structuredPatch = {},
          type = "create",
          userModified = false,
        },
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 224443,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PreToolUse",
        permission_mode = "plan",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          max_results = 1,
          query = "select:ExitPlanMode",
        },
        tool_name = "ToolSearch",
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 224459,
      event = {
        cwd = "/project",
        duration_ms = 3,
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolUse",
        permission_mode = "plan",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          max_results = 1,
          query = "select:ExitPlanMode",
        },
        tool_name = "ToolSearch",
        tool_response = {
          matches = {
            "ExitPlanMode",
          },
          query = "select:ExitPlanMode",
          total_deferred_tools = 279,
        },
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 225641,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolBatch",
        permission_mode = "plan",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_calls = {
          {
            tool_input = {
              content = '# Plan: create hello.txt containing "hi"\n\n## Context\nThe user wants a file `hello.txt` containing the word "hi". The working directory (`/home/user/.cache/project/proj`) is empty and not a git repo, so there is nothing to reuse and no commit is involved.\n\n## Steps\n1. Create `/home/user/.cache/project/proj/hello.txt` with the content `hi` (single line, trailing newline) using the Write tool.\n2. Verify by reading the file back (or `cat hello.txt`) and confirming it contains exactly `hi`.\n\n## Verification\n`cat hello.txt` prints `hi`.\n',
              file_path = "/home/user/.claude/plans/plan-how-to-create-compressed-mountain.md",
            },
            tool_name = "Write",
            tool_response = "File created successfully at: /home/user/.claude/plans/plan-how-to-create-compressed-mountain.md (file state is current in your context — no need to Read it back)",
            tool_use_id = "id",
          },
          {
            tool_input = {
              max_results = 1,
              query = "select:ExitPlanMode",
            },
            tool_name = "ToolSearch",
            tool_response = {
              {
                tool_name = "ExitPlanMode",
                type = "tool_reference",
              },
            },
            tool_use_id = "id",
          },
        },
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 227588,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PreToolUse",
        permission_mode = "plan",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          plan = '# Plan: create hello.txt containing "hi"\n\n## Context\nThe user wants a file `hello.txt` containing the word "hi". The working directory (`/home/user/.cache/project/proj`) is empty and not a git repo, so there is nothing to reuse and no commit is involved.\n\n## Steps\n1. Create `/home/user/.cache/project/proj/hello.txt` with the content `hi` (single line, trailing newline) using the Write tool.\n2. Verify by reading the file back (or `cat hello.txt`) and confirming it contains exactly `hi`.\n\n## Verification\n`cat hello.txt` prints `hi`.\n',
          planFilePath = "/home/user/.claude/plans/plan-how-to-create-compressed-mountain.md",
        },
        tool_name = "ExitPlanMode",
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 227636,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PermissionRequest",
        permission_mode = "plan",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          plan = '# Plan: create hello.txt containing "hi"\n\n## Context\nThe user wants a file `hello.txt` containing the word "hi". The working directory (`/home/user/.cache/project/proj`) is empty and not a git repo, so there is nothing to reuse and no commit is involved.\n\n## Steps\n1. Create `/home/user/.cache/project/proj/hello.txt` with the content `hi` (single line, trailing newline) using the Write tool.\n2. Verify by reading the file back (or `cat hello.txt`) and confirming it contains exactly `hi`.\n\n## Verification\n`cat hello.txt` prints `hi`.\n',
          planFilePath = "/home/user/.claude/plans/plan-how-to-create-compressed-mountain.md",
        },
        tool_name = "ExitPlanMode",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 233633,
      event = {
        cwd = "/project",
        hook_event_name = "Notification",
        message = "Claude Code needs your approval for the plan",
        notification_type = "permission_prompt",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
  },
  question = {
    {
      at = 45119,
      event = {
        cwd = "/project",
        hook_event_name = "UserPromptSubmit",
        permission_mode = "default",
        prompt = "Use the AskUserQuestion tool to ask me which color I prefer, with the options red and blue. Do nothing else.",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 46213,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PreToolUse",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          questions = {
            {
              header = "Color",
              multiSelect = false,
              options = {
                {
                  description = "Choose red",
                  label = "Red",
                },
                {
                  description = "Choose blue",
                  label = "Blue",
                },
              },
              question = "Which color do you prefer?",
            },
          },
        },
        tool_name = "AskUserQuestion",
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 46242,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PermissionRequest",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          questions = {
            {
              header = "Color",
              multiSelect = false,
              options = {
                {
                  description = "Choose red",
                  label = "Red",
                },
                {
                  description = "Choose blue",
                  label = "Blue",
                },
              },
              question = "Which color do you prefer?",
            },
          },
        },
        tool_name = "AskUserQuestion",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 52244,
      event = {
        cwd = "/project",
        hook_event_name = "Notification",
        message = "Claude needs your permission",
        notification_type = "permission_prompt",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 55756,
      event = {
        cwd = "/project",
        duration_ms = 1,
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolUse",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          annotations = {},
          answers = {
            ["Which color do you prefer?"] = "Red",
          },
          questions = {
            {
              header = "Color",
              multiSelect = false,
              options = {
                {
                  description = "Choose red",
                  label = "Red",
                },
                {
                  description = "Choose blue",
                  label = "Blue",
                },
              },
              question = "Which color do you prefer?",
            },
          },
        },
        tool_name = "AskUserQuestion",
        tool_response = {
          annotations = {},
          answers = {
            ["Which color do you prefer?"] = "Red",
          },
          questions = {
            {
              header = "Color",
              multiSelect = false,
              options = {
                {
                  description = "Choose red",
                  label = "Red",
                },
                {
                  description = "Choose blue",
                  label = "Blue",
                },
              },
              question = "Which color do you prefer?",
            },
          },
        },
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 55780,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolBatch",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_calls = {
          {
            tool_input = {
              questions = {
                {
                  header = "Color",
                  multiSelect = false,
                  options = {
                    {
                      description = "Choose red",
                      label = "Red",
                    },
                    {
                      description = "Choose blue",
                      label = "Blue",
                    },
                  },
                  question = "Which color do you prefer?",
                },
              },
            },
            tool_name = "AskUserQuestion",
            tool_response = 'Your questions have been answered: "Which color do you prefer?"="Red". You can now continue with these answers in mind.',
            tool_use_id = "id",
          },
        },
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 56442,
      event = {
        cwd = "/project",
        delta = "You prefer red.",
        final = true,
        hook_event_name = "MessageDisplay",
        index = 0,
        message_id = "id",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
        turn_id = "id",
      },
    },
    {
      at = 56442,
      event = {
        background_tasks = {},
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "Stop",
        last_assistant_message = "You prefer red.",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_crons = {},
        session_id = "id",
        stop_hook_active = false,
        transcript_path = "/project/t.jsonl",
      },
    },
  },
  tool_and_prose = {
    {
      at = 21923,
      event = {
        cwd = "/project",
        hook_event_name = "UserPromptSubmit",
        permission_mode = "default",
        prompt = "First say one short sentence about what you will do. Then run `ls -la` with the Bash tool. Then explain the output in one paragraph of about 80 words, no bullet points.",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 23277,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PreToolUse",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          command = "ls -la",
          description = "List all files in current directory with details",
        },
        tool_name = "Bash",
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 23409,
      event = {
        cwd = "/project",
        duration_ms = 92,
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolUse",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_input = {
          command = "ls -la",
          description = "List all files in current directory with details",
        },
        tool_name = "Bash",
        tool_response = {
          interrupted = false,
          isImage = false,
          noOutputExpected = false,
          stderr = "",
          stdout = "total 8\ndrwxr-xr-x 2 user user 4096 Nov  3 17:03 .\ndrwxr-xr-x 3 user user 4096 Nov  3 17:03 ..",
        },
        tool_use_id = "id",
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 23424,
      event = {
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "PostToolBatch",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        tool_calls = {
          {
            tool_input = {
              command = "ls -la",
              description = "List all files in current directory with details",
            },
            tool_name = "Bash",
            tool_response = "total 8\ndrwxr-xr-x 2 user user 4096 Nov  3 17:03 .\ndrwxr-xr-x 3 user user 4096 Nov  3 17:03 ..",
            tool_use_id = "id",
          },
        },
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 24277,
      event = {
        cwd = "/project",
        delta = "I'll list the current directory's contents.\n\n",
        final = false,
        hook_event_name = "MessageDisplay",
        index = 0,
        message_id = "id",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
        turn_id = "id",
      },
    },
    {
      at = 25034,
      event = {
        background_tasks = {},
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "Stop",
        last_assistant_message = "I'll list the current directory's contents.\n\nThe listing is empty apart from the two standard entries, `.` and `..`, so this directory has no files or subfolders yet. It is owned by `user` and was last modified on November 3 at 17:03. Its permissions are `drwxr-xr-x`, so the owner can write and everyone else can only read and enter it. The parent directory was modified at the same time. This matches the session notes describing the project as greenfield: nothing has been scaffolded here yet, and the directory is not a git repository.",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_crons = {},
        session_id = "id",
        stop_hook_active = false,
        transcript_path = "/project/t.jsonl",
      },
    },
    {
      at = 25034,
      event = {
        cwd = "/project",
        delta = "The listing is empty apart from the two standard entries, `.` and `..`, so this directory has no files or subfolders yet. It is owned by `user` and was last modified on November 3 at 17:03. Its permissions are `drwxr-xr-x`, so the owner can write and everyone else can only read and enter it. The parent directory was modified at the same time. This matches the session notes describing the project as greenfield: nothing has been scaffolded here yet, and the directory is not a git repository.",
        final = true,
        hook_event_name = "MessageDisplay",
        index = 1,
        message_id = "id",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_id = "id",
        transcript_path = "/project/t.jsonl",
        turn_id = "id",
      },
    },
    {
      at = 26236,
      event = {
        agent_id = "id",
        agent_transcript_path = "/project/t.jsonl",
        agent_type = "",
        background_tasks = {},
        cwd = "/project",
        effort = {
          level = "medium",
        },
        hook_event_name = "SubagentStop",
        permission_mode = "default",
        prompt_id = "id",
        scratchpad_dir = "/project/scratchpad",
        session_crons = {},
        session_id = "id",
        stop_hook_active = false,
        transcript_path = "/project/t.jsonl",
      },
    },
  },
}
