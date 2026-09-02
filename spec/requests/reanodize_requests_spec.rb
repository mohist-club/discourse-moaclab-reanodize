# frozen_string_literal: true

require "rails_helper"

describe "Moaclab re-anodize requests" do
  fab!(:user)
  fab!(:manager) { Fabricate(:user) }
  fab!(:group) { Fabricate(:group, name: "reanodize_managers") }

  before do
    SiteSetting.moaclab_reanodize_enabled = true
    SiteSetting.moaclab_reanodize_manager_group_name = "reanodize_managers"
    group.add(manager)
  end

  let(:payload) do
    {
      kit_name: "Matrix 8XV",
      needs_strip_polish: true,
      anodize_scope: "topBottom",
      tracking_number: "SF123456",
      shipping_address: "Shanghai",
      receiver_name: "Wayne",
      receiver_phone: "13800000000",
      qq: "10001",
      color_code: "GMK N9",
      case_files: ["case.jpg"],
      payment_order_no: "ALIPAY123",
      payment_files: ["paid.png"],
    }
  end

  it "requires login to create a request" do
    post "/moaclab/reanodize/requests", params: payload
    expect(response.status).to eq(403)
  end

  it "creates a request for a logged-in user" do
    sign_in(user)

    post "/moaclab/reanodize/requests", params: payload

    expect(response.status).to eq(200)
    json = response.parsed_body
    expect(json["public_id"]).to start_with("RA-")
    expect(json["estimated_total"]).to eq(350)
    expect(json["status"]).to eq("pending")
  end

  it "blocks regular users from admin request list" do
    sign_in(user)

    get "/moaclab/reanodize/admin/requests"

    expect(response.status).to eq(403)
  end

  it "allows managers to view admin request list" do
    sign_in(manager)

    get "/moaclab/reanodize/admin/requests"

    expect(response.status).to eq(200)
    expect(response.parsed_body["requests"]).to eq([])
  end
end
