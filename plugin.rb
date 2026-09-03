# frozen_string_literal: true

# name: discourse-moaclab-reanodize
# about: Stores and manages Moaclab re-anodize service requests.
# meta_topic_id: 0
# version: 0.2.1
# authors: Moaclab, Codex
# url: https://moaclab.com
# required_version: 3.3.0

require "securerandom"
require "erb"
require "cgi"

enabled_site_setting :moaclab_reanodize_enabled

after_initialize do
  module ::DiscourseMoaclabReanodize
    PLUGIN_NAME = "discourse-moaclab-reanodize"
    INDEX_KEY = "requests:index"
    NEXT_ID_KEY = "requests:next_id"
    STATUSES = %w[pending confirmed completed cancelled].freeze
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

      def self.safe_files(value)
        Array
          .wrap(value)
          .filter_map do |item|
            if item.respond_to?(:to_unsafe_h)
              item = item.to_unsafe_h
            elsif item.respond_to?(:to_h) && !item.is_a?(String)
              item = item.to_h
            end

            if item.is_a?(Hash)
              normalized = {}
              %w[url short_url original_filename name id sha1].each do |key|
                raw = item[key] || item[key.to_sym]
                normalized[key] = raw.to_s.strip if raw.present?
              end
              normalized.present? ? normalized : nil
            else
              file = item.to_s.strip
              file.present? ? file : nil
            end
          end
          .first(20)
      end

      def self.notify_user_update(previous, updated, actor)
        return if previous.blank? || updated.blank?

        status_changed = previous["status"].to_s != updated["status"].to_s
        note_changed = previous["admin_note"].to_s != updated["admin_note"].to_s
        return unless status_changed || note_changed

        user = User.find_by(id: updated["user_id"].to_i)
        return if user.blank?

        status_label = STATUS_LABELS[updated["status"]] || updated["status"]
        note = updated["admin_note"].to_s.strip
        raw = +"你的重新阳极需求有新的处理更新。\n\n"
        raw << "- 需求编号：#{updated["public_id"]}\n"
        raw << "- 套件名称：#{updated["kit_name"]}\n"
        raw << "- 当前状态：#{status_label}\n"
        raw << "- 处理人：@#{actor.username}\n"
        raw << "- 内部备注：#{note}\n" if note.present?

        PostCreator.create!(
          Discourse.system_user,
          title: "重新阳极需求更新：#{updated["public_id"]}",
          raw: raw,
          target_usernames: user.username,
          archetype: Archetype.private_message,
        )
      rescue => error
        Rails.logger.warn("#{PLUGIN_NAME}: failed to notify request #{updated["id"]}: #{error.class} #{error.message}")
      end

      def self.notify_user_created(request)
        return if request.blank?

        user = User.find_by(id: request["user_id"].to_i)
        return if user.blank?

        raw = +"你的重新阳极需求已提交成功。\n\n"
        raw << "- 需求编号：#{request["public_id"]}\n"
        raw << "- 套件名称：#{request["kit_name"]}\n"
        raw << "- 当前状态：#{STATUS_LABELS[request["status"]] || request["status"]}\n"
        raw << "- 预估费用：#{request["estimated_total"]} 元\n\n"
        raw << "后续处理进度会继续通过系统消息通知你。"

        PostCreator.create!(
          Discourse.system_user,
          title: "重新阳极需求已提交：#{request["public_id"]}",
          raw: raw,
          target_usernames: user.username,
          archetype: Archetype.private_message,
        )
      rescue => error
        Rails.logger.warn("#{PLUGIN_NAME}: failed to notify created request #{request["id"]}: #{error.class} #{error.message}")
      end

    class RequestsController < ::ApplicationController
      requires_plugin "discourse-moaclab-reanodize"

      before_action :ensure_logged_in
      before_action :ensure_manager, only: %i[index update stats admin]
      skip_before_action :check_xhr, only: %i[create mine index update stats admin access]

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
            "qq" => required_string(:qq),
            "color_code" => required_string(:color_code),
            "case_files" => DiscourseMoaclabReanodize.safe_files(params[:case_files]),
            "payment_order_no" => required_string(:payment_order_no),
            "payment_files" => DiscourseMoaclabReanodize.safe_files(params[:payment_files]),
          )

        DiscourseMoaclabReanodize.notify_user_created(request)
        render json: serialize_request(request)
      end

      def mine
        requests = DiscourseMoaclabReanodize.all.select { |request| request["user_id"].to_i == current_user.id }
        render json: { requests: requests.first(50).map { |request| serialize_request(request) } }
      end

      def access
        render json: { can_manage: DiscourseMoaclabReanodize.manager?(current_user) }
      end

      def index
        requests = DiscourseMoaclabReanodize.all
        status = admin_status_param
        requests = requests.select { |request| request["status"] == status } if status.present?

        if params[:q].present?
          needle = params[:q].to_s.strip.downcase
          requests =
            requests.select do |request|
              %w[public_id kit_name qq payment_order_no username receiver_name receiver_phone tracking_number].any? do |key|
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
        DiscourseMoaclabReanodize.notify_user_update(record, updated, current_user)

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
        status = admin_status_param
        requests = requests.select { |request| request["status"] == status } if status.present?

        if params[:q].present?
          needle = params[:q].to_s.strip.downcase
          requests =
            requests.select do |request|
              %w[public_id kit_name qq payment_order_no username receiver_name receiver_phone tracking_number].any? do |key|
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

      def admin_status_param
        status = params[:status].to_s
        return status if STATUSES.include?(status)
        return "" if status == "all"

        "pending"
      end

      def admin_tab_html
        active = admin_status_param
        query = params[:q].to_s.strip
        tabs = [["", "全部"], ["pending", "待确认"], ["confirmed", "已确认"], ["completed", "已完成"], ["cancelled", "已取消"]]

        tabs.map do |value, label|
          parts = []
          parts << "status=#{h(value.present? ? value : "all")}"
          parts << "q=#{h(CGI.escape(query))}" if query.present?
          href = "/moaclab/reanodize/admin"
          href = "#{href}?#{parts.join("&")}" if parts.present?
          active_class = active == value ? " is-active" : ""
          %(<a class="status-tab#{active_class}" href="#{href}">#{h(label)}</a>)
        end.join
      end

      def image_file?(value)
        value.to_s.match?(/\.(avif|gif|jpe?g|png|webp)(\?.*)?\z/i)
      end

      def file_hash(value)
        return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
        return value.to_h if value.respond_to?(:to_h) && !value.is_a?(String)

        {}
      end

      def file_label(value)
        attrs = file_hash(value)
        label = attrs["original_filename"] || attrs[:original_filename] || attrs["name"] || attrs[:name]
        label = value.to_s if label.blank?
        File.basename(label.to_s)
      end

      def upload_url(value)
        attrs = file_hash(value)
        raw = (attrs["url"] || attrs[:url] || attrs["short_url"] || attrs[:short_url] || value).to_s.strip
        return "" if raw.blank?
        return raw if raw.start_with?("http://", "https://", "/uploads/", "/optimized/")

        upload_id = attrs["id"] || attrs[:id]
        if upload_id.present?
          upload = Upload.find_by(id: upload_id.to_i) rescue nil
          return upload.url if upload&.url.present?
        end

        if raw.start_with?("upload://")
          upload = Upload.get_from_url(raw) rescue nil
          return upload.url if upload&.url.present?
        end

        basename = file_label(value)
        like_name = ActiveRecord::Base.sanitize_sql_like(basename)
        sha_prefix = basename.sub(/\.[^.]+\z/, "")
        upload = Upload.where(original_filename: raw).order(id: :desc).first rescue nil
        upload ||= Upload.where(original_filename: basename).order(id: :desc).first rescue nil
        upload ||= Upload.where("url LIKE ?", "%#{like_name}").order(id: :desc).first rescue nil
        upload ||= Upload.where("sha1 LIKE ?", "#{sha_prefix}%").order(id: :desc).first rescue nil
        return upload.url if upload&.url.present?

        ""
      end

      def file_items_html(files, empty_label, compact: false)
        items = Array.wrap(files).reject do |file|
          file.blank? || (file.respond_to?(:empty?) && file.empty?)
        end
        return %(<span class="muted">#{h(empty_label)}</span>) if items.blank?

        items.map do |file|
          url = upload_url(file)
          label = file_label(file)

          if url.present? && image_file?(url)
            label_html = compact ? "" : %(<span>#{h(label)}</span>)
            %(<a class="file-thumb#{compact ? " is-compact" : ""}" href="#" title="#{h(label)}" data-admin-image="#{h(url)}" data-admin-image-label="#{h(label)}"><img src="#{h(url)}" alt="#{h(label)}">#{label_html}</a>)
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
          row_files = file_items_html(item["payment_files"], "无", compact: true)
          payment_files = file_items_html(item["payment_files"], "未上传付款截图")
          case_files = file_items_html(item["case_files"], "未上传案例图")

          <<~HTML
            <details class="request-item">
              <summary class="request-row">
                <span class="cell request-id">
                  <em>编号</em>
                  <strong class="mono">#{h(item["public_id"])}</strong>
                  <small>#{h(created_at)}</small>
                </span>
                <span class="cell"><em>用户</em><strong>#{h(item["username"] || "-")}</strong></span>
                <span class="cell"><em>套件</em><strong>#{h(item["kit_name"])}</strong><small>#{h(item["color_code"])}</small></span>
                <span class="cell"><em>服务</em><strong>#{h(service)}</strong><small>#{h(item["estimated_total"])} 元</small></span>
                <span class="cell"><em>QQ</em><strong>#{h(item["qq"])}</strong></span>
                <span class="cell file-cell"><em>付款截图</em><span class="row-files">#{row_files}</span></span>
                <span class="cell"><em>状态</em><span class="status">#{h(STATUS_LABELS[item["status"]] || item["status"])}</span></span>
              </summary>
              <form class="request-detail" method="post" action="/moaclab/reanodize/admin/requests/#{h(item["id"])}">
                <input type="hidden" name="authenticity_token" value="#{h(form_authenticity_token)}">
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
                      <span class="status">#{h(STATUS_LABELS[item["status"]] || item["status"])}</span>
                    </div>
                  </section>
                </div>
              </form>
            </details>
          HTML
        end.join
      end

      def admin_stats_html
        stats = stats_payload
        [["总数", stats[:total]], ["待确认", stats[:pending]], ["已确认", stats[:by_status]["confirmed"].to_i], ["已完成", stats[:completed]], ["已取消", stats[:by_status]["cancelled"].to_i]].map do |label, value|
          %(<div class="stat"><span>#{h(label)}</span><strong>#{h(value)}</strong></div>)
        end.join
      end

      def admin_script_nonce_attr
        nonce = content_security_policy_nonce rescue nil
        nonce.present? ? %( nonce="#{h(nonce)}") : ""
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
                main{max-width:1240px;margin:0 auto;padding:28px}
                header{display:flex;justify-content:space-between;gap:16px;align-items:end;margin-bottom:18px}
                h1{margin:0;font-size:30px;line-height:1.2;letter-spacing:0}
                h2,h3{margin:0;line-height:1.25;letter-spacing:0}
                .stats{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;margin-bottom:16px}
                .stat{background:#fff;border:1px solid #dfe7f1;border-radius:14px;box-shadow:0 14px 34px rgba(31,45,71,.06);padding:18px}
                .stat span{display:block;color:#6c87a8;font-weight:750}.stat strong{font-size:30px;line-height:1.1}
                .status-tabs{display:flex;gap:8px;margin:0 0 14px;overflow-x:auto}
                .status-tab{display:inline-flex;align-items:center;justify-content:center;min-height:40px;padding:0 16px;border:1px solid #cbd8e8;border-radius:999px;background:#fff;color:#6c87a8;text-decoration:none;font-weight:850;white-space:nowrap}
                .status-tab.is-active{border-color:#386fae;background:#edf4ff;color:#386fae}
                .toolbar{display:flex;gap:10px;margin-bottom:14px;flex-wrap:wrap}
                input,select,textarea,button{border:1px solid #cbd8e8;border-radius:10px;background:#fff;color:#17202a;font:inherit}
                input,select{height:42px;padding:0 12px}button{height:42px;padding:0 16px;font-weight:800;cursor:pointer}
                .muted{color:#6c87a8}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
                .request-list{display:grid;gap:10px}
                .request-list-head,.request-row{display:grid;grid-template-columns:1.45fr .72fr 1fr 1fr .95fr .86fr .62fr 42px;gap:12px;align-items:center}
                .request-list-head{padding:0 18px 8px;color:#6c87a8;font-size:12px;font-weight:850}
                .request-item{background:#fff;border:1px solid #dfe7f1;border-radius:14px;box-shadow:0 14px 34px rgba(31,45,71,.06);overflow:hidden}
                .request-item[open]{box-shadow:0 18px 44px rgba(31,45,71,.1)}
                .request-row{position:relative;min-height:84px;padding:14px 18px;list-style:none;cursor:pointer}
                .request-row::-webkit-details-marker{display:none}
                .request-row:hover{background:#fbfdff}
                .request-row:after{content:"展开";justify-self:end;color:#386fae;font-size:12px;font-weight:850}
                .request-item[open] .request-row:after{content:"收起"}
                .request-row .cell{min-width:0;display:grid;gap:3px}
                .request-row em{display:none;color:#6c87a8;font-size:12px;font-style:normal;font-weight:850}
                .request-row strong{display:block;font-size:14px;line-height:1.35;overflow-wrap:anywhere}
                .request-row small{display:block;color:#6c87a8;font-size:12px;line-height:1.35;overflow-wrap:anywhere}
                .row-files{display:flex;gap:6px;align-items:center;min-width:0}
                .request-body{display:grid;grid-template-columns:1.05fr 1.05fr .9fr;gap:14px;padding:16px;border-top:1px solid #e4ebf3;background:#fbfdff}
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
                .file-thumb:hover{border-color:#386fae;box-shadow:0 8px 20px rgba(56,111,174,.14)}
                .file-thumb img{width:100%;height:74px;object-fit:cover;border-radius:9px;background:#eef3f8}
                .file-thumb.is-compact{width:46px;height:46px;min-height:0;padding:3px;grid-template-rows:1fr;border-radius:10px}
                .file-thumb.is-compact img{height:38px;border-radius:7px}
                .file-thumb span,.file-name,.file-link{font-size:12px;line-height:1.25;text-align:center;overflow-wrap:anywhere}
                .admin-block{display:grid;gap:12px;align-content:start}
                .admin-block label{display:grid;gap:6px}
                .info-block label>span{display:block;color:#6c87a8;font-size:13px;font-weight:800;margin-bottom:6px}
                .admin-block select{width:100%}
                textarea{width:100%;min-height:112px;padding:10px 12px;resize:vertical}
                .admin-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
                .admin-actions button{background:#17202a;color:#fff;border-color:#17202a}
                .status{display:inline-flex;padding:5px 11px;border-radius:999px;background:#edf4ff;color:#386fae;font-weight:800;font-size:13px}
                .empty{padding:32px;text-align:center;color:#6c87a8;font-weight:800;background:#fff;border:1px solid #dfe7f1;border-radius:14px}
                .image-lightbox{position:fixed;inset:0;z-index:20;display:none;place-items:center;padding:24px;background:rgba(8,13,22,.78)}
                .image-lightbox.is-open{display:grid}
                .image-lightbox figure{position:relative;width:min(980px,calc(100vw - 48px));max-height:calc(100vh - 48px);margin:0;padding:16px;border-radius:18px;background:#fff;box-shadow:0 28px 70px rgba(0,0,0,.32)}
                .image-lightbox img{display:block;width:100%;max-height:calc(100vh - 120px);object-fit:contain;border-radius:12px;background:#f6f8fb}
                .image-lightbox figcaption{margin-top:10px;color:#6c87a8;font-weight:800;text-align:center;overflow-wrap:anywhere}
                .image-lightbox button{position:absolute;top:10px;right:10px;width:38px;height:38px;padding:0;border-radius:999px;background:#fff;box-shadow:0 8px 18px rgba(0,0,0,.18);font-size:24px;line-height:1}
                @media(max-width:1040px){main{padding:18px}.stats{grid-template-columns:repeat(2,1fr)}.request-list-head{display:none}.request-row{grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.request-row em{display:block}.request-row:after{justify-self:start}.request-body{grid-template-columns:1fr}.toolbar input{width:100%}}
                @media(max-width:560px){main{padding:14px}h1{font-size:25px}.stats{grid-template-columns:1fr}.stat{padding:14px}.toolbar{display:grid}.toolbar>*{width:100%}.request-row{grid-template-columns:1fr;min-height:0;padding:14px}.request-body{padding:12px}.info-block{padding:14px}dl{grid-template-columns:1fr;gap:4px}.file-grid{grid-template-columns:repeat(2,minmax(0,1fr))}}
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
                <nav class="status-tabs" aria-label="状态筛选">#{admin_tab_html}</nav>
                <form class="toolbar" method="get" action="/moaclab/reanodize/admin">
                  <input name="q" value="#{h(params[:q])}" placeholder="搜索编号、套件、QQ、订单号">
                  <input type="hidden" name="status" value="#{h(admin_status_param.present? ? admin_status_param : "all")}">
                  <button type="submit">搜索</button>
                </form>
                <section class="request-list">
                  <div class="request-list-head">
                    <span>编号</span><span>用户</span><span>套件</span><span>服务</span><span>QQ</span><span>付款截图</span><span>状态</span><span></span>
                  </div>
                  #{admin_request_rows}
                </section>
              </main>
              <div class="image-lightbox" id="image-lightbox" aria-hidden="true">
                <figure>
                  <button type="button" aria-label="关闭">×</button>
                  <img src="" alt="">
                  <figcaption></figcaption>
                </figure>
              </div>
              <script#{admin_script_nonce_attr}>
                const lightbox = document.getElementById("image-lightbox");
                const lightboxImage = lightbox.querySelector("img");
                const lightboxCaption = lightbox.querySelector("figcaption");
                const closeLightbox = () => {
                  lightbox.classList.remove("is-open");
                  lightbox.setAttribute("aria-hidden", "true");
                  lightboxImage.removeAttribute("src");
                  lightboxImage.alt = "";
                  lightboxCaption.textContent = "";
                };
                document.querySelectorAll("[data-admin-image]").forEach((link) => {
                  link.addEventListener("click", (event) => {
                    event.preventDefault();
                    event.stopPropagation();
                    lightboxImage.src = link.dataset.adminImage;
                    lightboxImage.alt = link.dataset.adminImageLabel || "上传图片";
                    lightboxCaption.textContent = link.dataset.adminImageLabel || "";
                    lightbox.classList.add("is-open");
                    lightbox.setAttribute("aria-hidden", "false");
                  });
                });
                lightbox.addEventListener("click", (event) => {
                  if (event.target === lightbox) closeLightbox();
                });
                lightbox.querySelector("button").addEventListener("click", closeLightbox);
                document.addEventListener("keydown", (event) => {
                  if (event.key === "Escape" && lightbox.classList.contains("is-open")) closeLightbox();
                });
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
    get "/moaclab/reanodize/access" => "discourse_moaclab_reanodize/requests#access", defaults: { format: :json }
    get "/moaclab/reanodize/admin" => "discourse_moaclab_reanodize/requests#admin", defaults: { format: :html }
    get "/moaclab/reanodize/admin/requests" => "discourse_moaclab_reanodize/requests#index", defaults: { format: :json }
    post "/moaclab/reanodize/admin/requests/:id" => "discourse_moaclab_reanodize/requests#update", defaults: { format: :html }
    patch "/moaclab/reanodize/admin/requests/:id" => "discourse_moaclab_reanodize/requests#update", defaults: { format: :json }
    get "/moaclab/reanodize/admin/stats" => "discourse_moaclab_reanodize/requests#stats", defaults: { format: :json }
  end
end
