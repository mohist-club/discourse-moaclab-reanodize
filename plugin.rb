# frozen_string_literal: true

# name: discourse-moaclab-reanodize
# about: Stores and manages Moaclab re-anodize service requests.
# meta_topic_id: 0
# version: 0.1.3
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

      def image_file?(value)
        value.to_s.match?(/\.(avif|gif|jpe?g|png|webp)(\?.*)?\z/i)
      end

      def upload_url(value)
        raw = value.to_s.strip
        return "" if raw.blank?
        return raw if raw.start_with?("http://", "https://", "/uploads/", "/optimized/")

        if raw.start_with?("upload://")
          upload = Upload.get_from_url(raw) rescue nil
          return upload.url if upload&.url.present?
        end

        ""
      end

      def file_items_html(files, empty_label)
        items = Array.wrap(files).map { |file| file.to_s.strip }.reject(&:blank?)
        return %(<span class="muted">#{h(empty_label)}</span>) if items.blank?

        items.map do |file|
          url = upload_url(file)
          label = File.basename(file)

          if url.present? && image_file?(url)
            %(<a class="file-thumb" href="#{h(url)}" target="_blank" rel="noopener"><img src="#{h(url)}" alt="#{h(label)}"><span>#{h(label)}</span></a>)
          elsif url.present?
            %(<a class="file-link" href="#{h(url)}" target="_blank" rel="noopener">#{h(label)}</a>)
          else
            %(<span class="file-name">#{h(label)}</span>)
          end
        end.join
      end

      def admin_request_rows
        requests = admin_requests
        return %(<div class="empty">暂无提交记录</div>) if requests.blank?

        requests.map do |item|
          created_at = Time.zone.parse(item["created_at"].to_s).strftime("%Y-%m-%d %H:%M") rescue item["created_at"]
          service = "#{SCOPE_LABELS[item["anodize_scope"]]}#{item["needs_strip_polish"] ? " / 退漆打磨" : ""}"
          payment_files = file_items_html(item["payment_files"], "未上传付款截图")
          case_files = file_items_html(item["case_files"], "未上传案例图")

          <<~HTML
            <article class="request-card">
              <form method="post" action="/moaclab/reanodize/admin/requests/#{h(item["id"])}">
                <input type="hidden" name="authenticity_token" value="#{h(form_authenticity_token)}">
                <div class="request-head">
                  <div class="request-id">
                    <span>编号</span>
                    <strong class="mono">#{h(item["public_id"])}</strong>
                    <em>#{h(created_at)}</em>
                  </div>
                  <div>
                    <span>用户</span>
                    <strong>#{h(item["username"] || "-")}</strong>
                  </div>
                  <div>
                    <span>套件 / 颜色</span>
                    <strong>#{h(item["kit_name"])}</strong>
                    <em>#{h(item["color_code"])}</em>
                  </div>
                  <div>
                    <span>服务 / 费用</span>
                    <strong>#{h(service)}</strong>
                    <em>#{h(item["estimated_total"])} 元</em>
                  </div>
                </div>
                <div class="request-body">
                  <section class="info-block">
                    <h2>联系与寄件</h2>
                    <dl>
                      <dt>联系人</dt><dd>#{h(item["receiver_name"])}</dd>
                      <dt>手机号</dt><dd>#{h(item["receiver_phone"])}</dd>
                      <dt>QQ</dt><dd>#{h(item["qq"])}</dd>
                      <dt>快递单号</dt><dd>#{h(item["tracking_number"])}</dd>
                      <dt>收货地址</dt><dd>#{h(item["shipping_address"])}</dd>
                    </dl>
                  </section>
                  <section class="info-block">
                    <h2>付款与图片</h2>
                    <dl>
                      <dt>支付宝订单号</dt><dd>#{h(item["payment_order_no"])}</dd>
                    </dl>
                    <div class="file-area">
                      <h3>已付截图</h3>
                      <div class="file-grid">#{payment_files}</div>
                    </div>
                    <div class="file-area">
                      <h3>图片案例</h3>
                      <div class="file-grid">#{case_files}</div>
                    </div>
                  </section>
                  <section class="info-block admin-block">
                    <h2>处理</h2>
                    <label>
                      <span>状态</span>
                      <select name="status">#{admin_status_options(item["status"])}</select>
                    </label>
                    <label>
                      <span>内部备注</span>
                      <textarea name="admin_note">#{h(item["admin_note"])}</textarea>
                    </label>
                    <div class="admin-actions">
                      <button type="submit">保存</button>
                      <span class="status">#{h(STATUS_LABELS[item["status"]])}</span>
                    </div>
                  </section>
                </div>
              </form>
            </article>
          HTML
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
                *{box-sizing:border-box}
                body{margin:0;background:#f6f8fb;color:#17202a;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
                main{max-width:1180px;margin:0 auto;padding:28px}
                header{display:flex;justify-content:space-between;gap:16px;align-items:end;margin-bottom:18px}
                h1{margin:0;font-size:30px;line-height:1.2;letter-spacing:0}
                h2,h3{margin:0;line-height:1.25;letter-spacing:0}
                .stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:18px}
                .stat{background:#fff;border:1px solid #dfe7f1;border-radius:14px;box-shadow:0 14px 34px rgba(31,45,71,.06);padding:18px}
                .stat span{display:block;color:#6c87a8;font-weight:750}.stat strong{font-size:30px;line-height:1.1}
                .toolbar{display:flex;gap:10px;margin-bottom:14px;flex-wrap:wrap}
                input,select,textarea,button{border:1px solid #cbd8e8;border-radius:10px;background:#fff;color:#17202a;font:inherit}
                input,select{height:42px;padding:0 12px}button{height:42px;padding:0 16px;font-weight:800;cursor:pointer}
                .muted{color:#6c87a8}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
                .request-list{display:grid;gap:16px}
                .request-card{background:#fff;border:1px solid #dfe7f1;border-radius:16px;box-shadow:0 16px 40px rgba(31,45,71,.07);overflow:hidden}
                .request-head{display:grid;grid-template-columns:1.35fr .8fr 1.3fr 1fr;gap:0;border-bottom:1px solid #e4ebf3;background:linear-gradient(180deg,#fff,#fbfdff)}
                .request-head>div{min-width:0;padding:16px 18px;border-right:1px solid #e4ebf3}
                .request-head>div:last-child{border-right:0}
                .request-head span,.info-block label>span{display:block;color:#6c87a8;font-size:13px;font-weight:800;margin-bottom:6px}
                .request-head strong{display:block;font-size:17px;line-height:1.35;overflow-wrap:anywhere}
                .request-head em{display:block;color:#6c87a8;font-style:normal;margin-top:3px;overflow-wrap:anywhere}
                .request-body{display:grid;grid-template-columns:1.1fr 1.1fr .85fr;gap:14px;padding:16px}
                .info-block{min-width:0;border:1px solid #e4ebf3;border-radius:14px;padding:16px;background:#fff}
                .info-block h2{font-size:16px;margin-bottom:12px}
                dl{display:grid;grid-template-columns:82px minmax(0,1fr);gap:8px 12px;margin:0}
                dt{color:#6c87a8;font-weight:800}
                dd{margin:0;font-weight:650;overflow-wrap:anywhere}
                .file-area{margin-top:14px}
                .file-area h3{color:#6c87a8;font-size:13px;margin-bottom:8px}
                .file-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(92px,1fr));gap:10px}
                .file-thumb,.file-link,.file-name{display:flex;align-items:center;justify-content:center;min-height:42px;border:1px solid #dfe7f1;border-radius:12px;background:#f8fbff;color:#386fae;font-weight:800;text-decoration:none;overflow:hidden}
                .file-thumb{display:grid;grid-template-rows:74px auto;padding:6px;gap:6px}
                .file-thumb img{width:100%;height:74px;object-fit:cover;border-radius:9px;background:#eef3f8}
                .file-thumb span,.file-name,.file-link{font-size:12px;line-height:1.25;text-align:center;overflow-wrap:anywhere}
                .admin-block{display:grid;gap:12px;align-content:start}
                .admin-block label{display:grid;gap:6px}
                .admin-block select{width:100%}
                textarea{width:100%;min-height:112px;padding:10px 12px;resize:vertical}
                .admin-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
                .admin-actions button{background:#17202a;color:#fff;border-color:#17202a}
                .status{display:inline-flex;padding:5px 11px;border-radius:999px;background:#edf4ff;color:#386fae;font-weight:800;font-size:13px}
                .empty{padding:32px;text-align:center;color:#6c87a8;font-weight:800;background:#fff;border:1px solid #dfe7f1;border-radius:14px}
                @media(max-width:900px){main{padding:18px}.stats{grid-template-columns:repeat(2,1fr)}.request-head,.request-body{grid-template-columns:1fr}.request-head>div{border-right:0;border-bottom:1px solid #e4ebf3}.request-head>div:last-child{border-bottom:0}.toolbar input{width:100%}}
                @media(max-width:560px){main{padding:14px}h1{font-size:25px}.stats{grid-template-columns:1fr}.stat{padding:14px}.toolbar{display:grid}.toolbar>*{width:100%}.request-body{padding:12px}.info-block{padding:14px}dl{grid-template-columns:1fr;gap:4px}.file-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
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
                <section class="request-list">
                  #{admin_request_rows}
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
