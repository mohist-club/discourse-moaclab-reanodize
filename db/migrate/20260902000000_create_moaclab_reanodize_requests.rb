# frozen_string_literal: true

class CreateMoaclabReanodizeRequests < ActiveRecord::Migration[7.0]
  def change
    create_table :moaclab_reanodize_requests do |t|
      t.integer :user_id, null: false
      t.string :public_id, null: false
      t.string :kit_name, null: false
      t.boolean :needs_strip_polish, null: false, default: false
      t.string :anodize_scope, null: false, default: "single"
      t.integer :estimated_total, null: false, default: 200
      t.string :tracking_number, null: false
      t.text :shipping_address, null: false
      t.string :receiver_name, null: false
      t.string :receiver_phone, null: false
      t.string :qq
      t.string :color_code, null: false
      t.json :case_files, null: false, default: []
      t.string :payment_order_no, null: false
      t.json :payment_files, null: false, default: []
      t.string :status, null: false, default: "pending"
      t.text :admin_note
      t.timestamps
    end

    add_index :moaclab_reanodize_requests, :user_id
    add_index :moaclab_reanodize_requests, :public_id, unique: true
    add_index :moaclab_reanodize_requests, :status
    add_index :moaclab_reanodize_requests, :created_at
  end
end
