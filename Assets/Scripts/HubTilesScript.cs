using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;
using System;
using System.Collections;
using System.Collections.Generic;

public class HubTilesScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public GameObject hubBuilder;
    public HubBuilderScript hubBuilderScript;
    public GameObject player;
    public HubPlayerScript playerScript;
    public Dictionary<Vector3, GameObject> tileLookup;
    public bool isPointerOverUI = false;
    public GameObject tileCursor;
    public GameObject mouseDownTile = null;

    IEnumerator WaitForHubBuilder()
    {
        while (!hubBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        // populate tileLookup
        tileLookup = new Dictionary<Vector3, GameObject>();
        for (int i = 0; i < this.transform.childCount; i++)
        {
            GameObject tile = this.transform.GetChild(i).gameObject;
            tileLookup.Add(tile.transform.position, tile);
        }
        finishedBuilding = true;
    }

    void Start()
    {
        hubBuilder = GameObject.Find("Hub Builder");
        hubBuilderScript = hubBuilder.GetComponent<HubBuilderScript>();
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<HubPlayerScript>();
        StartCoroutine(WaitForHubBuilder());
    }

    public float Distance(Vector3 startPosition, Vector3 endPosition)
    {
        // diagonal movement is allowed
        float dX = Math.Abs(startPosition.x - endPosition.x);
        float dY = Math.Abs(startPosition.y - endPosition.y);
        return Math.Max(dX, dY);
    }

    void Update()
    {
        if (EventSystem.current.IsPointerOverGameObject())
        {
            isPointerOverUI = true;
        }
        else
        {
            isPointerOverUI = false;
        }
        // to-do - only raycast for cursor once in preparation for the following
        // handle mouse over for tile cursor
        if (Mouse.current != null)
        {
            if (!isPointerOverUI)
            {
                Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
                RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
                if (hit.collider != null)
                {
                    GameObject tile = hit.collider.gameObject;
                    TileScript tileScript = tile.GetComponent<TileScript>();
                    if (tileScript != null)
                    {
                        if (tileCursor == null)
                        {
                            // create tile cursor
                            tileCursor = new GameObject("Tile Cursor");
                            tileCursor.transform.parent = this.transform.parent; // = hub
                            SpriteRenderer tileCursorRenderer = tileCursor.AddComponent<SpriteRenderer>();
                            tileCursorRenderer.sortingOrder = 0;
                            Sprite tileCursorSprite = Resources.Load<Sprite>("TileCursor");
                            tileCursorRenderer.sprite = tileCursorSprite;
                        }
                        if (tileCursor != null)
                        {
                            tileCursor.transform.position = tile.transform.position; 
                            SpriteRenderer tileCursorRenderer = tileCursor.GetComponent<SpriteRenderer>();
                            Color tileCursorColor = tileCursorRenderer.color;
                            if (Distance(player.transform.position, tile.transform.position) <= playerScript.Speed)
                            {
                                tileCursorColor.a = 1.0f;
                            }
                            else
                            {
                                tileCursorColor.a = 0.125f;
                            }
                            tileCursorRenderer.color = tileCursorColor;
                            tileCursor.SetActive(true);
                        }
                    }
                    else
                    {
                        if (tileCursor != null)
                        {
                            tileCursor.SetActive(false);
                        }
                    }
                }
                else
                {
                    if (tileCursor != null)
                    {
                        tileCursor.SetActive(false);
                    }
                }
            }
        }
        // handle mouse down
        if (Mouse.current != null && Mouse.current.leftButton.wasPressedThisFrame)
        {
            if (!isPointerOverUI)
            {
                Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
                RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
                if (hit.collider != null)
                {
                    GameObject tile = hit.collider.gameObject;
                    TileScript tileScript = tile.GetComponent<TileScript>();
                    if (tileScript != null)
                    {
                        mouseDownTile = tile;
                    }
                    else
                    {
                        mouseDownTile = null;
                    }
                }
                else
                {
                    mouseDownTile = null;
                }
            }
            else
            {
                mouseDownTile = null;
            }
        }
        // handle mouse up
        if (Mouse.current != null && Mouse.current.leftButton.wasReleasedThisFrame)
        {
            if (!isPointerOverUI && mouseDownTile != null)
            {
                Vector2 mousePosition = Camera.main.ScreenToWorldPoint(Mouse.current.position.ReadValue());
                RaycastHit2D hit = Physics2D.Raycast(mousePosition, Vector2.zero);
                if (hit.collider != null)
                {
                    GameObject tile = hit.collider.gameObject;
                    // only process click if mouse up is on the same tile as mouse down
                    if (tile == mouseDownTile)
                    {
                        TileScript tileScript = tile.GetComponent<TileScript>();
                        if (tileScript != null)
                        {
                            if (Distance(player.transform.position, tile.transform.position) <= playerScript.Speed)
                            {
                                playerScript.MoveTo(tile.transform.position);
                            }
                        }
                    }
                }
            }
            mouseDownTile = null;
        }
    }
}
