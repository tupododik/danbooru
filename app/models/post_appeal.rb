class PostAppeal < ApplicationRecord
  class Error < Exception ; end

  belongs_to :creator, :class_name => "User"
  belongs_to :post
  validates_presence_of :reason, :creator_ip_addr
  validate :validate_post_is_inactive
  validate :validate_creator_is_not_limited
  before_validation :initialize_creator, :on => :create
  validates_uniqueness_of :creator_id, :scope => :post_id, :message => "have already appealed this post"

  module SearchMethods
    def post_tags_match(query)
      where(post_id: PostQueryBuilder.new(query).build.reorder(""))
    end

    def resolved
      joins(:post).where("posts.is_deleted = false and posts.is_flagged = false")
    end

    def unresolved
      joins(:post).where("posts.is_deleted = true or posts.is_flagged = true")
    end

    def for_user(user_id)
      where("creator_id = ?", user_id)
    end

    def recent
      where("created_at >= ?", 1.day.ago)
    end

    def for_creator(user_id)
      where("creator_id = ?", user_id)
    end

    def search(params)
      q = super

      q = q.attribute_matches(:reason, params[:reason_matches])

      if params[:creator_id].present?
        q = q.where(creator_id: params[:creator_id].split(",").map(&:to_i))
      end

      if params[:creator_name].present?
        q = q.where("creator_id = (select _.id from users _ where lower(_.name) = ?)", params[:creator_name].mb_chars.downcase.strip.tr(" ", "_"))
      end

      if params[:post_id].present?
        q = q.where(post_id: params[:post_id].split(",").map(&:to_i))
      end

      if params[:post_tags_match].present?
        q = q.post_tags_match(params[:post_tags_match])
      end

      q = q.resolved if params[:is_resolved].to_s.truthy?
      q = q.unresolved if params[:is_resolved].to_s.falsy?

      q.apply_default_order(params)
    end
  end

  extend SearchMethods

  def resolved?
    post.present? && !post.is_deleted? && !post.is_flagged?
  end

  def is_resolved
    resolved?
  end

  def validate_creator_is_not_limited
    if appeal_count_for_creator >= Danbooru.config.max_appeals_per_day
      errors[:creator] << "can appeal at most #{Danbooru.config.max_appeals_per_day} post a day"
    end
  end

  def validate_post_is_inactive
    if resolved?
      errors[:post] << "is active"
    end
  end

  def initialize_creator
    self.creator_id = CurrentUser.id
    self.creator_ip_addr = CurrentUser.ip_addr
  end

  def appeal_count_for_creator
    PostAppeal.for_user(creator_id).recent.count
  end

  def method_attributes
    super + [:is_resolved]
  end
end
