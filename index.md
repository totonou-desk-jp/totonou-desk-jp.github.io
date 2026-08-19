---
layout: default
title: 整うデスク
description: デスク周りを、静かに整えるための実用記事メディア。
---

<section class="hero">
  <h1 class="hero__title">整うデスク</h1>
  <p class="hero__lead">机の上が整うと、頭の中も整う。<br>デスク周りの整え方を、静かに届けます。</p>
</section>

<section class="post-list">
  <h2 class="post-list__heading">記事一覧</h2>
  {% if site.posts.size > 0 %}
  <ul class="post-list__items">
    {% for post in site.posts %}
    <li class="post-list__item">
      <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
      <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: '%Y年%m月%d日' }}</time>
    </li>
    {% endfor %}
  </ul>
  {% else %}
  <p>記事は準備中です。</p>
  {% endif %}
</section>
