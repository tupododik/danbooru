require 'digest/sha1'

class Dmail < ApplicationRecord
  # if a person sends spam to more than 10 users within a 24 hour window, automatically ban them for 3 days.
  AUTOBAN_THRESHOLD = 10
  AUTOBAN_WINDOW = 24.hours
  AUTOBAN_DURATION = 3

  validates_presence_of :title, :body, on: :create
  validate :validate_sender_is_not_banned, on: :create

  belongs_to :owner, :class_name => "User"
  belongs_to :to, :class_name => "User"
  belongs_to :from, :class_name => "User"

  after_initialize :initialize_attributes, if: :new_record?
  before_create :auto_read_if_filtered
  after_create :update_recipient
  after_commit :send_email, on: :create

  concerning :SpamMethods do
    class_methods do
      def is_spammer?(user)
        return false if user.is_gold?

        spammed_users = sent_by(user).where(is_spam: true).where("created_at > ?", AUTOBAN_WINDOW.ago).distinct.count(:to_id)
        spammed_users >= AUTOBAN_THRESHOLD
      end

      def ban_spammer(spammer)
        spammer.bans.create! do |ban|
          ban.banner = User.system
          ban.reason = "Spambot."
          ban.duration = AUTOBAN_DURATION
        end
      end
    end

    def spam?
      SpamDetector.new(self).spam?
    end
  end

  module AddressMethods
    def to_name=(name)
      self.to = User.find_by_name(name)
    end

    def initialize_attributes
      self.from_id ||= CurrentUser.id
      self.creator_ip_addr ||= CurrentUser.ip_addr
    end
  end

  module FactoryMethods
    extend ActiveSupport::Concern

    module ClassMethods
      def create_split(params)
        copy = nil

        Dmail.transaction do
          # recipient's copy
          copy = Dmail.new(params)
          copy.owner_id = copy.to_id
          copy.is_spam = copy.spam?
          copy.save unless copy.to_id == copy.from_id

          # sender's copy
          copy = Dmail.new(params)
          copy.owner_id = copy.from_id
          copy.is_read = true
          copy.save

          Dmail.ban_spammer(copy.from) if Dmail.is_spammer?(copy.from)
        end

        copy
      end

      def create_automated(params)
        CurrentUser.as_system do
          dmail = Dmail.new(from: User.system, **params)
          dmail.owner = dmail.to
          dmail.save
          dmail
        end
      end
    end

    def build_response(options = {})
      Dmail.new do |dmail|
        if title =~ /Re:/
          dmail.title = title
        else
          dmail.title = "Re: #{title}"
        end
        dmail.owner_id = from_id
        dmail.body = quoted_body
        dmail.to_id = from_id unless options[:forward]
        dmail.from_id = to_id
      end
    end
  end

  module ApiMethods
    def hidden_attributes
      super + [:message_index]
    end
    
    def method_attributes
      super + [:key]
    end
  end
  
  module SearchMethods
    def sent_by(user)
      where("dmails.from_id = ? AND dmails.owner_id != ?", user.id, user.id)
    end

    def active
      where("is_deleted = ?", false)
    end

    def deleted
      where("is_deleted = ?", true)
    end

    def read
      where(is_read: true)
    end

    def unread
      where("is_read = false and is_deleted = false")
    end

    def visible
      where("owner_id = ?", CurrentUser.id)
    end

    def to_name_matches(name)
      where("to_id = (select _.id from users _ where lower(_.name) = ?)", name.mb_chars.downcase)
    end

    def from_name_matches(name)
      where("from_id = (select _.id from users _ where lower(_.name) = ?)", name.mb_chars.downcase)
    end

    def search(params)
      q = super

      q = q.attribute_matches(:title, params[:title_matches])
      q = q.attribute_matches(:body, params[:message_matches], index_column: :message_index)

      if params[:to_name].present?
        q = q.to_name_matches(params[:to_name])
      end

      if params[:to_id].present?
        q = q.where("to_id = ?", params[:to_id].to_i)
      end

      if params[:from_name].present?
        q = q.from_name_matches(params[:from_name])
      end

      if params[:from_id].present?
        q = q.where("from_id = ?", params[:from_id].to_i)
      end

      params[:is_spam] = false unless params[:is_spam].present?
      q = q.attribute_matches(:is_spam, params[:is_spam])
      q = q.attribute_matches(:is_read, params[:is_read])
      q = q.attribute_matches(:is_deleted, params[:is_deleted])

      q = q.read if params[:read].to_s.truthy?
      q = q.unread if params[:read].to_s.falsy?

      q.apply_default_order(params)
    end
  end

  include AddressMethods
  include FactoryMethods
  include ApiMethods
  extend SearchMethods

  def validate_sender_is_not_banned
    if from.try(:is_banned?)
      errors[:base] << "Sender is banned and cannot send messages"
    end
  end

  def quoted_body
    "[quote]\n#{from.pretty_name} said:\n\n#{body}\n[/quote]\n\n"
  end

  def send_email
    if is_recipient? && !is_spam? && to.receive_email_notifications? && to.email =~ /@/
      UserMailer.dmail_notice(self).deliver_now
    end
  end

  def mark_as_read!
    update_column(:is_read, true)
    owner.dmails.unread.count.tap do |unread_count|
      owner.update(has_mail: (unread_count > 0), unread_dmail_count: unread_count)
    end
  end

  def is_automated?
    from == User.system
  end

  def is_sender?
    owner == from
  end

  def is_recipient?
    owner == to
  end

  def filtered?
    CurrentUser.dmail_filter.try(:filtered?, self)
  end

  def auto_read_if_filtered
    if is_recipient? && to.dmail_filter.try(:filtered?, self)
      self.is_read = true
    end
  end

  def update_recipient
    if is_recipient? && !is_deleted? && !is_read?
      to.update(has_mail: true, unread_dmail_count: to.dmails.unread.count)
    end
  end

  def key
    verifier = ActiveSupport::MessageVerifier.new(Danbooru.config.email_key, serializer: JSON, digest: "SHA256")
    verifier.generate("#{title} #{body}")
  end

  def visible_to?(user, key)
    owner_id == user.id || (user.is_moderator? && key == self.key)
  end
end
