# frozen_string_literal: true

# name: discourse-moaclab-reanodize
# about: Stores and manages Moaclab re-anodize service requests.
# meta_topic_id: 0
# version: 0.1.2
# authors: Moaclab, Codex
# url: https://moaclab.com
# required_version: 3.3.0

require "securerandom"
require "erb"

enabled_site_setting :moaclab_reanodize_enabled

after_initialize do
  module ::DiscourseMoaclabReanodize
    PLUGIN_NAME = "discourse-moaclab-reanodize"
    INDEX_KEY = "requests:index"
    NEXT_ID_KEY = "requests:next_id"
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
      (scope == "topBottom" ? 300 : 200) + (needs_strip_polish ? 50 : 0)
    end

    def self.public_id
      "RA-#{Time.zone.now.strftime("%Y%m%d")}-#{SecureRandom.hex(3).upcase}"
    end

    def self.index
      Array.wrap(PluginStore.get(PLUGIN_NAME, INDEX_KEY))
    end

    def self.write_index(ids)
      PluginStore.set(PLUGIN_NAME, INDEX_KEY, ids.map(&:to_i).uniq)
    end

    def self.next_id
      id = PluginStore.get(PLUGIN_NAME, NEXT_ID_KEY).to_i
      id = 1 if id < 1
      PluginStore.set(PLUGIN_NAME, NEXT_ID_KEY, id + 1)
      id
    end

    def self.key(id)
      "requests:#{id.to_i}"
    end

    def self.create(attrs)
      id = next_id
      now = Time.zone.now.iso8601
      request = attrs.merge(
        "id" => id,
        "public_id" => public_id,
        "status" => "pending",
        "admin_note" => "",
        "created_at" => now,
        "updated_at" => now,
      )

      PluginStore.set(PLUGIN_NAME, key(id), request)
      write_index([id] + index)
      request
    end

    def self.find(id)
      PluginStore.get(PLUGIN_NAME, key(id))
    end

    def self.update(id, attrs)
      request = find(id)
      return nil if request.blank?

      updated = request.merge(attrs).merge("updated_at" => Time.zone.now.iso8601)
      PluginStore.set(PLUGIN_NAME, key(id), updated)
      updated
    end

    def self.all
      index.filter_map { |id| find(id) }
    end

    def self.safe_array(value)
      Array.wrap(value).map { |item| item.to_s.strip }.reject(&:blank?).first(20)
    end

    class RequestsController < ::ApplicationController
      requires_plugin "discourse-moaclab-reanodize"

      before_action :ensure_logged_in
      before_action :ensure_manager, only: %i[index update stats admin]
      skip_before_action :check_xhr, only: %i[create mine index update stats admin]

      def create
        scope = permitted_scope(params[:anodize_scope])
        needs_strip_polish = ActiveModel::Type::Boolean.new.cast(params[:needs_strip_polish])

        request =
          DiscourseMoaclabReanodize.create(
            "user_id" => current_user.id,
            "username" => current_user.username,
            "kit_name" => required_string(:kit_name),
            "needs_strip_polish" => needs_strip_polish,
            "anodize_scope" => scope,
            "estimated_total" => DiscourseMoaclabReanodize.estimate_total(scope, needs_strip_polish),
            "tracking_number" => required_string(:tracking_number),
            "shipping_address" => required_string(:shipping_address),
            "receiver_name" => required_string(:receiver_name),
            "receiver_phone" => required_string(:receiver_phone),
            "qq" => params[:qq].to_s.strip,
            "color_code" => required_string(:color_code),
            "case_files" => DiscourseMoaclabReanodize.safe_array(params[:case_files]),
            "payment_order_no" => required_string(:payment_order_no),
            "payment_files" => DiscourseMoaclabReanodize.safe_array(params[:payment_files]),
          )

        render json: serialize_request(request)
      end

      def mine
        requests = DiscourseMoaclabReanodize.all.select { |request| request["user_id"].to_i == current_user.id }
        render json: { requests: requests.first(50).map { |request| serialize_request(request) } }
      end

      def index
        requests = DiscourseMoaclabReanodize.all
        requests = requests.select { |request| request["status"] == params[:status].to_s } if STATUSES.include?(params[:status].to_s)

        if params[:q].present?
          needle = params[:q].to_s.strip.downcase
          requests =
            requests.select do |request|
              %w[public_id kit_name qq payment_order_no username].any? do |key|
                request[key].to_s.downcase.include?(needle)
              end
            end
        end

        render json: { requests: requests.first(200).map { |request| serialize_request(request, include_user: true) }, stats: stats_payload }
      end

      def update
        record = DiscourseMoaclabReanodize.find(params[:id])
        raise Discourse::NotFound if record.blank?

        attrs = {}
        status = params[:status].to_s
        attrs["status"] = status if STATUSES.include?(status)
        attrs["admin_note"] = params[:admin_note].to_s if params.key?(:admin_note)

        updated = DiscourseMoaclabReanodize.update(params[:id], attrs)

        if request.format.html?
          redirect_to "/moaclab/reanodize/admin"
        else
          render json: serialize_request(updated, include_user: true)
        end
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

      def serialize_request(request, include_user: false)
        payload = {
          id: request["id"],
          public_id: request["public_id"],
          kit_name: request["kit_name"],
          needs_strip_polish: request["needs_strip_polish"],
          anodize_scope: request["anodize_scope"],
          anodize_scope_label: SCOPE_LABELS[request["anodize_scope"]],
          estimated_total: request["estimated_total"],
          tracking_number: request["tracking_number"],
          shipping_address: request["shipping_address"],
          receiver_name: request["receiver_name"],
          receiver_phone: request["receiver_phone"],
          qq: request["qq"],
          color_code: request["color_code"],
          case_files: request["case_files"] || [],
          payment_order_no: request["payment_order_no"],
          payment_files: request["payment_files"] || [],
          status: request["status"],
          status_label: STATUS_LABELS[request["status"]],
          admin_note: request["admin_note"],
          created_at: request["created_at"],
          updated_at: request["updated_at"],
        }

        payload[:user] = { id: request["user_id"], username: request["username"] } if include_user
        payload
      end

      def stats_payload
        requests = DiscourseMoaclabReanodize.all
        by_status = requests.group_by { |request| request["status"] }.transform_values(&:size)

        {
          total: requests.size,
          pending: by_status["pending"].to_i,
          processing: by_status["processing"].to_i,
          completed: by_status["completed"].to_i,
          by_status: by_status,
        }
      end

      def admin_requests
        requests = DiscourseMoaclabReanodize.all
        requests = requests.select { |request| request["status"] == params[:status].to_s } if STATUSES.include?(params[:status].to_s)

        if params[:q].present?
          needle = params[:q].to_s.strip.downcase
          requests =
            requests.select do |request|
              %w[public_id kit_name qq payment_order_no username].any? do |key|
                request[key].to_s.downcase.include?(needle)
              end
            end
        end

        requests.first(200)
      end

      def h(value)
        ERB::Util.html_escape(value.to_s)
      end

      def admin_status_options(selected)
        STATUSES.map do |status|
          selected_attr = status == selected ? " selected" : ""
          %(<option value="#{h(status)}"#{selected_attr}>#{h(STATUS_LABELS[status])}</option>)
        end.join
      end

      def admin_request_rows
        requests = admin_requests
        return %(<tr><td class="empty" colspan="9">暂无提交记录</td></tr>) if requests.blank?

        requests.map do |item|
          created_at = Time.zone.parse(item["created_at"].to_s).strftime("%Y-%m-%d %H:%M") rescue item["created_at"]
          payment_files = Array.wrap(item["payment_files"]).join(", ")
          service = "#{SCOPE_LABELS[item["anodize_scope"]]}#{item["needs_strip_polish"] ? " / 退漆打磨" : ""}"

          <<~ROW
            <tr>
              <td><strong class="mono">#{h(item["public_id"])}</strong><br><span class="muted">#{h(created_at)}</span></td>
              <td>#{h(item["username"] || "-")}</td>
              <td><strong>#{h(item["kit_name"])}</strong><br><span class="muted">#{h(item["color_code"])}</span></td>
              <td>#{h(service)}<br><strong>#{h(item["estimated_total"])}</strong></td>
              <td>#{h(item["receiver_name"])} #{h(item["receiver_phone"])}<br><span class="muted">#{h(item["tracking_number"])}</span><br>#{h(item["shipping_address"])}</td>
              <td>#{h(item["payment_order_no"])}<br><span class="muted">#{h(payment_files)}</span></td>
              <td>
                <form method="post" action="/moaclab/reanodize/admin/requests/#{h(item["id"])}">
                  <input type="hidden" name="authenticity_token" value="#{h(form_authenticity_token)}">
                  <select name="status">#{admin_status_options(item["status"])}</select>
              </td>
              <td><textarea name="admin_note">#{h(item["admin_note"])}</textarea></td>
              <td><button type="submit">保存</button><br><span class="status">#{h(STATUS_LABELS[item["status"]])}</span></form></td>
            </tr>
          ROW
        end.join
      end

      def admin_stats_html
        stats = stats_payload
        [["总数", stats[:total]], ["待确认", stats[:pending]], ["处理中", stats[:processing]], ["已完成", stats[:completed]]].map do |label, value|
          %(<div class="stat"><span>#{h(label)}</span><strong>#{h(value)}</strong></div>)
        end.join
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
                .status{display:inline-flex;margin-top:8px;padding:3px 9px;border-radius:999px;background:#edf4ff;color:#386fae;font-weight:800;font-size:12px}
                .empty{padding:28px;text-align:center;color:#6c87a8;font-weight:800}
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
                <section class="stats">#{admin_stats_html}</section>
                <form class="toolbar" method="get" action="/moaclab/reanodize/admin">
                  <input name="q" value="#{h(params[:q])}" placeholder="搜索编号、套件、QQ、订单号">
                  <select name="status">
                    <option value="">全部状态</option>
                    #{STATUSES.map { |status| %(<option value="#{h(status)}"#{status == params[:status].to_s ? " selected" : ""}>#{h(STATUS_LABELS[status])}</option>) }.join}
                  </select>
                  <button type="submit">筛选</button>
                </form>
                <section class="panel">
                  <table>
                    <thead><tr><th>编号</th><th>用户</th><th>套件</th><th>服务</th><th>联系/寄件</th><th>付款</th><th>状态</th><th>备注</th><th>操作</th></tr></thead>
                    <tbody>#{admin_request_rows}</tbody>
                  </table>
                </section>
              </main>
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
    post "/moaclab/reanodize/admin/requests/:id" => "discourse_moaclab_reanodize/requests#update", defaults: { format: :html }
    patch "/moaclab/reanodize/admin/requests/:id" => "discourse_moaclab_reanodize/requests#update", defaults: { format: :json }
    get "/moaclab/reanodize/admin/stats" => "discourse_moaclab_reanodize/requests#stats", defaults: { format: :json }
  end
end
