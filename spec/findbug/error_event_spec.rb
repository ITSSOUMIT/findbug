# frozen_string_literal: true

RSpec.describe Findbug::ErrorEvent do
  let(:valid_attrs) do
    {
      fingerprint: "abc123",
      exception_class: "RuntimeError",
      message: "boom",
      first_seen_at: Time.now,
      last_seen_at: Time.now
    }
  end

  describe "validations" do
    it "is valid with the minimum required attributes" do
      expect(described_class.new(valid_attrs)).to be_valid
    end

    it "requires a fingerprint" do
      event = described_class.new(valid_attrs.merge(fingerprint: nil))
      expect(event).not_to be_valid
      expect(event.errors[:fingerprint]).to include("can't be blank")
    end

    it "requires an exception_class" do
      event = described_class.new(valid_attrs.merge(exception_class: nil))
      expect(event).not_to be_valid
    end

    it "rejects invalid statuses" do
      event = described_class.new(valid_attrs.merge(status: "made_up"))
      expect(event).not_to be_valid
    end

    it "rejects invalid severities" do
      event = described_class.new(valid_attrs.merge(severity: "panic"))
      expect(event).not_to be_valid
    end
  end

  describe "JSON accessors (context / request_data) on text columns" do
    let(:event) { described_class.new(valid_attrs) }

    it "round-trips a Hash through the database" do
      event.context = { user_id: 42, role: "admin" }
      event.save!
      reloaded = described_class.find(event.id)
      expect(reloaded.context).to eq("user_id" => 42, "role" => "admin")
    end

    it "round-trips an empty Hash" do
      event.context = {}
      event.save!
      expect(described_class.find(event.id).context).to eq({})
    end

    it "returns an empty Hash when the column value is nil" do
      event.save!
      # Bypass our setter to insert a real NULL into the text column.
      event.update_column(:context, nil)
      expect(event.reload.context).to eq({})
    end

    it "stores the raw String when assigned a pre-serialised JSON String" do
      event.context = '{"already":"json"}'
      event.save!
      raw = event.class.connection.select_value(
        "SELECT context FROM findbug_error_events WHERE id = #{event.id}"
      )
      expect(raw).to eq('{"already":"json"}')
      expect(event.reload.context).to eq("already" => "json")
    end

    it "does not double-encode when re-saving a String value" do
      event.context = '{"foo":"bar"}'
      event.save!
      event.reload
      event.touch
      raw = event.class.connection.select_value(
        "SELECT context FROM findbug_error_events WHERE id = #{event.id}"
      )
      expect(raw).to eq('{"foo":"bar"}')
    end

    it "stores nil when explicitly assigned nil" do
      event.context = nil
      event.save!
      raw = event.class.connection.select_value(
        "SELECT context FROM findbug_error_events WHERE id = #{event.id}"
      )
      expect(raw).to be_nil
    end

    it "returns an empty Hash if the stored value is malformed JSON" do
      event.save!
      event.update_column(:context, "this is not json")
      expect(event.reload.context).to eq({})
    end

    it "applies the same behaviour to request_data" do
      event.request_data = { ip: "127.0.0.1" }
      event.save!
      expect(described_class.find(event.id).request_data).to eq("ip" => "127.0.0.1")
    end
  end

  describe "JSON accessors on json/jsonb columns" do
    # Simulate a Postgres environment by stubbing the column type as :jsonb.
    let(:event) { described_class.new(valid_attrs) }

    before do
      allow(described_class).to receive(:columns_hash).and_return(
        "context"      => instance_double("col", type: :jsonb),
        "request_data" => instance_double("col", type: :json)
      )
    end

    it "writes the native Hash through to write_attribute (no .to_json)" do
      expect(event).to receive(:write_attribute).with(:context, { user_id: 7 })
      event.context = { user_id: 7 }
    end

    it "passes a String value through unchanged (lets AR's type cast handle it)" do
      expect(event).to receive(:write_attribute).with(:context, '{"a":1}')
      event.context = '{"a":1}'
    end

    it "passes nil through unchanged" do
      expect(event).to receive(:write_attribute).with(:context, nil)
      event.context = nil
    end
  end

  describe ".upsert_from_event" do
    let(:event_data) do
      {
        fingerprint: "fp-1",
        exception_class: "ArgumentError",
        message: "bad input",
        context: { user_id: 1 },
        severity: "error",
        environment: "test"
      }
    end

    it "creates a new ErrorEvent on first occurrence" do
      expect { described_class.upsert_from_event(event_data) }
        .to change(described_class, :count).by(1)
    end

    it "increments occurrence_count when the fingerprint is seen again" do
      described_class.upsert_from_event(event_data)
      result = described_class.upsert_from_event(event_data)
      expect(result.occurrence_count).to eq(2)
    end

    it "reopens a previously resolved error when it occurs again" do
      first = described_class.upsert_from_event(event_data)
      first.resolve!
      described_class.upsert_from_event(event_data)
      expect(first.reload.status).to eq(described_class::STATUS_UNRESOLVED)
    end

    it "deep-merges the context across occurrences" do
      described_class.upsert_from_event(event_data)
      described_class.upsert_from_event(event_data.merge(context: { plan: "pro" }))
      err = described_class.find_by(fingerprint: "fp-1")
      expect(err.context).to include("user_id" => 1, "plan" => "pro")
    end

    it "deep-merges the context extra accross occurrences" do
      err = described_class.upsert_from_event(
        event_data.merge(context: { user_id: 1, extra: { foo: "bar" } })
      )

      expect(err.reload.context).to include("user_id" => 1, "extra" => { "foo" => "bar" })

      new_extra = {
        foo: "baz",
        qux: true
      }

      described_class.upsert_from_event(
        event_data.merge(context: { extra: new_extra })
      )

      expect(err.reload.context).to include("user_id" => 1, "extra" => new_extra.stringify_keys)
    end

    it "serialises backtraces stored as arrays into JSON" do
      data = event_data.merge(backtrace: ["file:1", "file:2"])
      err = described_class.upsert_from_event(data)
      expect(err.backtrace_lines).to eq(["file:1", "file:2"])
    end
  end

  describe "status transitions" do
    let(:event) { described_class.create!(valid_attrs) }

    it "marks an error as resolved" do
      event.resolve!
      expect(event.status).to eq(described_class::STATUS_RESOLVED)
    end

    it "marks an error as ignored" do
      event.ignore!
      expect(event.status).to eq(described_class::STATUS_IGNORED)
    end

    it "reopens a resolved error" do
      event.resolve!
      event.reopen!
      expect(event.status).to eq(described_class::STATUS_UNRESOLVED)
    end
  end

  describe "context helpers" do
    let(:event) do
      described_class.create!(valid_attrs.merge(
        context: {
          "user"        => { "id" => 9, "email" => "u@example.com" },
          "request"     => { "path" => "/x" },
          "breadcrumbs" => [{ "msg" => "clicked" }],
          "tags"        => { "tier" => "pro" }
        }
      ))
    end

    it "exposes #user from context" do
      expect(event.user).to eq("id" => 9, "email" => "u@example.com")
    end

    it "exposes #request from context" do
      expect(event.request).to eq("path" => "/x")
    end

    it "exposes #breadcrumbs from context" do
      expect(event.breadcrumbs).to eq([{ "msg" => "clicked" }])
    end

    it "exposes #tags from context" do
      expect(event.tags).to eq("tier" => "pro")
    end

    it "returns sensible empty defaults when context is missing keys" do
      bare = described_class.create!(valid_attrs.merge(context: {}))
      expect(bare.user).to be_nil
      expect(bare.breadcrumbs).to eq([])
      expect(bare.tags).to eq({})
    end
  end
end
