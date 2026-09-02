# frozen_string_literal: true

# name: discourse-moaclab-reanodize
# about: Stores and manages Moaclab re-anodize service requests.
# meta_topic_id: 0
# version: 0.1.0
# authors: Moaclab, Codex
# url: https://moaclab.com
# required_version: 3.3.0

require "json"
require "securerandom"

enabled_site_setting :moaclab_reanodize_enabled

after_initialize do
  module ::DiscourseMoaclabReanodize
    STATUSES = %w[pending confirmed received processing completed cancelled].freeze
    SCOPES = %w[single topBottom].freeze

    STATUS_LABELS = {
      "pending" => "待确认",
      "confirmed" => "已确认",
      "received" => "已收件",
      "processing" => "处理中",
      "completed" => "已完成",
      "cancelled" => "已取消",
    }.freeze

    SCOPE_LABELS = {
      "single" => "单件",
      "topBottom" => "上下盖",
    }.freeze

    def self.manager?(user)
      return false if user.blank?
      return true if user.admin? || user.moderator?

      group_name = SiteSetting.moaclab_reanodize_manager_group_name.to_s.strip
      return false if group_name.blank?

      user.groups.where(name: group_name).exists?
    end

    def self.estimate_total(scope, needs_strip_polish)
      base = scope == "topBottom" ? 300 : 200
      base + (needs_strip_polish ? 50 : 0)
    end

    def self.public_id
      "RA-#{Time.zone.now.strftime("%Y%m%d")}-#{SecureRandom.hex(3).upcase}"
    end

    def self.notify_user(user, title, message, url)
      Notification.create!(
        notification_type: Notification.types[:custom],
        user_id: user.id,
        data: { title: title, message: message, url: url }.to_json,
      )
    rescue StandardError => e
      Rails.logger.warn("[moaclab-reanodize] notification failed: #{e.class}: #{e.message}")
    end

    class Request < ::ActiveRecord::Base
      self.table_name = "moaclab_reanodize_requests"

      belongs_to :user

      validates :public_id, :kit_name, :anodize_scope, :status, presence: true
      validates :anodize_scope, inclusion: { in: SCOPES }
      validates :status, inclusion: { in: STATUSES }
    end

    class RequestsController < ::ApplicationController
      requires_plugin "discourse-moaclab-reanodize"

      before_action :ensure_logged_in
      before_action :ensure_manager, only: %i[index update stats admin]
      skip_before_action :check_xhr, only: %i[create mine index update stats admin]

      def create
        scope = permitted_scope(params[:anodize_scope])
        needs_strip_polish = ActiveModel::Type::Boolean.new.cast(params[:needs_strip_polish])

        request = Request.create!(
          public_id: DiscourseMoaclabReanodize.public_id,
          user_id: current_user.id,
          kit_name: required_string(:kit_name),
          needs_strip_polish: needs_strip_polish,
          anodize_scope: scope,
          estimated_total: DiscourseMoaclabReanodize.estimate_total(scope, needs_strip_polish),
          tracking_number: required_string(:tracking_number),
          shipping_address: required_string(:shipping_address),
          receiver_name: required_string(:receiver_name),
          receiver_phone: required_string(:receiver_phone),
          qq: params[:qq].to_s.strip,
          color_code: required_string(:color_code),
          case_files: safe_array(params[:case_files]),
          payment_order_no: required_string(:payment_order_no),
          payment_files: safe_array(params[:payment_files]),
          status: "pending",
        )

        DiscourseMoaclabReanodize.notify_user(
          current_user,
          "重新阳极需求已提交",
          "你的重新阳极需求 #{request.public_id} 已提交，维护组会进行确认。",
          "/moaclab/reanodize/my",
        )

        render json: serialize_request(request)
      end

      def mine
        requests = Request.where(user_id: current_user.id).order(created_at: :desc).limit(50)
        render json: { requests: requests.map { |request| serialize_request(request) } }
      end

      def index
        requests = Request.includes(:user).order(created_at: :desc)
        requests = requests.where(status: params[:status]) if STATUSES.include?(params[:status].to_s)

        if params[:q].present?
          q = "%#{params[:q].to_s.strip}%"
          requests = requests.where(
            "kit_name ILIKE :q OR public_id ILIKE :q OR qq ILIKE :q OR payment_order_no ILIKE :q",
            q: q,
          )
        end

        render json: {
          requests: requests.limit(200).map { |request| serialize_request(request, include_user: true) },
          stats: stats_payload,
        }
      end

      def update
        request = Request.find(params[:id])
        previous_status = request.status

        status = params[:status].to_s
        request.status = status if STATUSES.include?(status)
        request.admin_note = params[:admin_note].to_s if params.key?(:admin_note)
        request.save!

        if previous_status != request.status
          DiscourseMoaclabReanodize.notify_user(
            request.user,
            "重新阳极需求状态更新",
            "#{request.public_id} 的状态已更新为：#{STATUS_LABELS[request.status]}。",
            "/moaclab/reanodize/my",
          )
        end

        render json: serialize_request(request, include_user: true)
      end

      def stats
        render json: stats_payload
      end

      def admin
        render html: admin_html.html_safe, layout: false
      end

      private

      def ensure_manager
        raise Discourse::InvalidAccess.new unless DiscourseMoaclabReanodize.manager?(current_user)
      end

      def required_string(key)
        value = params[key].to_s.strip
        raise Discourse::InvalidParameters.new(key) if value.blank?

        value
      end

      def permitted_scope(value)
        scope = value.to_s
        SCOPES.include?(scope) ? scope : "single"
      end

      def safe_array(value)
        Array.wrap(value).map { |item| item.to_s.strip }.reject(&:blank?).first(20)
      end

      def serialize_request(request, include_user: false)
        payload = {
          id: request.id,
          public_id: request.public_id,
          kit_name: request.kit_name,
          needs_strip_polish: request.needs_strip_polish,
          anodize_scope: request.anodize_scope,
          anodize_scope_label: SCOPE_LABELS[request.anodize_scope],
          estimated_total: request.estimated_total,
          tracking_number: request.tracking_number,
          shipping_address: request.shipping_address,
          receiver_name: request.receiver_name,
          receiver_phone: request.receiver_phone,
          qq: request.qq,
          color_code: request.color_code,
          case_files: request.case_files || [],
          payment_order_no: request.payment_order_no,
          payment_files: request.payment_files || [],
          status: request.status,
          status_label: STATUS_LABELS[request.status],
          admin_note: request.admin_note,
          created_at: request.created_at,
          updated_at: request.updated_at,
        }

        payload[:user] = { id: request.user_id, username: request.user&.username } if include_user
        payload
      end

      def stats_payload
        {
          total: Request.count,
          pending: Request.where(status: "pending").count,
          processing: Request.where(status: "processing").count,
          completed: Request.where(status: "completed").count,
          by_status: Request.group(:status).count,
        }
      end

      def admin_html
        <<~HTML
          <!doctype html>
          <html lang="zh-CN">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>重新阳极需求管理</title>
              <style>
                body{margin:0;background:#f6f8fb;color:#17202a;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
                main{max-width:1180px;margin:0 auto;padding:28px}
                header{display:flex;justify-content:space-between;gap:16px;align-items:end;margin-bottom:18px}
                h1{margin:0;font-size:28px}
                .stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:18px}
                .stat,.panel{background:#fff;border:1px solid #dfe7f1;border-radius:12px;box-shadow:0 12px 30px rgba(31,45,71,.06)}
                .stat{padding:16px}.stat span{display:block;color:#6c87a8;font-weight:700}.stat strong{font-size:28px}
                .toolbar{display:flex;gap:10px;margin-bottom:14px}
                input,select,textarea,button{border:1px solid #cbd8e8;border-radius:8px;background:#fff;color:#17202a;font:inherit}
                input,select{height:40px;padding:0 12px}button{height:40px;padding:0 14px;font-weight:700;cursor:pointer}
                table{width:100%;border-collapse:collapse;background:#fff;border-radius:12px;overflow:hidden}
                th,td{padding:12px;border-bottom:1px solid #e4ebf3;text-align:left;vertical-align:top}
                th{color:#6c87a8;font-size:13px}
                .muted{color:#6c87a8}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
                .status{display:inline-flex;padding:3px 9px;border-radius:999px;background:#edf4ff;color:#386fae;font-weight:800;font-size:12px}
                textarea{width:220px;min-height:42px;padding:8px 10px;resize:vertical}
                @media(max-width:760px){main{padding:16px}.stats{grid-template-columns:repeat(2,1fr)}header,.toolbar{display:grid}table,thead,tbody,tr,th,td{display:block}thead{display:none}tr{border-bottom:1px solid #dfe7f1}td{border-bottom:0}}
              </style>
            </head>
            <body>
              <main>
                <header>
                  <div>
                    <h1>重新阳极需求管理</h1>
                    <div class="muted">维护提交记录、处理状态和内部备注。</div>
                  </div>
                </header>
                <section class="stats" id="stats"></section>
                <section class="toolbar">
                  <input id="q" placeholder="搜索编号、套件、QQ、订单号">
                  <select id="status">
                    <option value="">全部状态</option>
                    #{STATUSES.map { |status| %(<option value="#{status}">#{STATUS_LABELS[status]}</option>) }.join}
                  </select>
                  <button id="search">筛选</button>
                </section>
                <section class="panel">
                  <table>
                    <thead><tr><th>编号</th><th>用户</th><th>套件</th><th>服务</th><th>联系/寄件</th><th>付款</th><th>状态</th><th>备注</th><th>操作</th></tr></thead>
                    <tbody id="rows"></tbody>
                  </table>
                </section>
              </main>
              <script>
                const statuses = #{STATUS_LABELS.to_json};
                const csrf = "#{form_authenticity_token}";
                const esc = (s) => String(s ?? "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\\"":"&quot;","'":"&#39;" }[c]));
                async function load() {
                  const params = new URLSearchParams();
                  if (q.value.trim()) params.set("q", q.value.trim());
                  if (status.value) params.set("status", status.value);
                  const res = await fetch(`/moaclab/reanodize/admin/requests?${params}`, { credentials: "same-origin" });
                  const data = await res.json();
                  stats.innerHTML = [
                    ["总数", data.stats.total],
                    ["待确认", data.stats.pending],
                    ["处理中", data.stats.processing],
                    ["已完成", data.stats.completed],
                  ].map(([label, value]) => `<div class="stat"><span>${label}</span><strong>${value}</strong></div>`).join("");
                  rows.innerHTML = data.requests.map(renderRow).join("");
                }
                function renderRow(item) {
                  return `<tr data-id="${item.id}">
                    <td><strong class="mono">${esc(item.public_id)}</strong><br><span class="muted">${new Date(item.created_at).toLocaleString()}</span></td>
                    <td>${esc(item.user?.username || "-")}</td>
                    <td><strong>${esc(item.kit_name)}</strong><br><span class="muted">${esc(item.color_code)}</span></td>
                    <td>${esc(item.anodize_scope_label)}${item.needs_strip_polish ? " / 退漆打磨" : ""}<br><strong>${esc(item.estimated_total)}</strong></td>
                    <td>${esc(item.receiver_name)} ${esc(item.receiver_phone)}<br><span class="muted">${esc(item.tracking_number)}</span><br>${esc(item.shipping_address)}</td>
                    <td>${esc(item.payment_order_no)}<br><span class="muted">${esc((item.payment_files || []).join(", "))}</span></td>
                    <td><select class="row-status">${Object.keys(statuses).map(s => `<option value="${s}" ${s === item.status ? "selected" : ""}>${statuses[s]}</option>`).join("")}</select></td>
                    <td><textarea class="row-note">${esc(item.admin_note || "")}</textarea></td>
                    <td><button class="save">保存</button><br><span class="status">${esc(item.status_label)}</span></td>
                  </tr>`;
                }
                rows.addEventListener("click", async (event) => {
                  if (!event.target.classList.contains("save")) return;
                  const tr = event.target.closest("tr");
                  const res = await fetch(`/moaclab/reanodize/admin/requests/${tr.dataset.id}`, {
                    method: "PATCH",
                    credentials: "same-origin",
                    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
                    body: JSON.stringify({ status: tr.querySelector(".row-status").value, admin_note: tr.querySelector(".row-note").value })
                  });
                  if (res.ok) load();
                });
                search.addEventListener("click", load);
                q.addEventListener("keydown", e => { if (e.key === "Enter") load(); });
                load();
              </script>
            </body>
          </html>
        HTML
      end
    end
  end

  Discourse::Application.routes.append do
    post "/moaclab/reanodize/requests" => "discourse_moaclab_reanodize/requests#create", defaults: { format: :json }
    get "/moaclab/reanodize/my" => "discourse_moaclab_reanodize/requests#mine", defaults: { format: :json }
    get "/moaclab/reanodize/admin" => "discourse_moaclab_reanodize/requests#admin", defaults: { format: :html }
    get "/moaclab/reanodize/admin/requests" => "discourse_moaclab_reanodize/requests#index", defaults: { format: :json }
    patch "/moaclab/reanodize/admin/requests/:id" => "discourse_moaclab_reanodize/requests#update", defaults: { format: :json }
    get "/moaclab/reanodize/admin/stats" => "discourse_moaclab_reanodize/requests#stats", defaults: { format: :json }
  end
end
