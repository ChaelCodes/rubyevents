require "test_helper"

class FavoriteUserTest < ActiveSupport::TestCase

  test "finds mutual favorite user" do
    chael = users(:chael)
    marco = users(:marco)

    my_favorite = FavoriteUser.create(user: chael, favorite_user: marco)
    mutual_favorite = FavoriteUser.new(user: marco, favorite_user: chael)

    assert_equal my_favorite.mutual_favorite_user, mutual_favorite
  end
end
