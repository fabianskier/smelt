defmodule SmeltWeb.PageController do
  use SmeltWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
