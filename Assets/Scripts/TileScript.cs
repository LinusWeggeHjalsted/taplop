using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;

public class TileScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject highlight;
    public Animator highlightAnimator;
    public bool isOccupied = false;
    private bool isHighlighted = false;
    public bool IsHighlighted
    {
        get
        {
            return this.isHighlighted;
        }
        set
        {
            if (turnLogic == null)
            {
                return;
            }
            // add to highlightedTileLookup when highlighting
            if (value && !this.isHighlighted)
            {
                Vector3 position = this.transform.position;
                traversableTilesScript.highlightedTileLookup.Add(position, this.gameObject);
            }
            // remove from highlightedTileLookup when unhighlighting
            else if (!value && this.isHighlighted)
            {
                Vector3 position = this.transform.position;
                traversableTilesScript.highlightedTileLookup.Remove(position);
            }
            this.isHighlighted = value;
            highlightAnimator.SetBool("isHighlighted", isHighlighted);
        }
    }
    private bool isEnd = false;
    public bool IsEnd
    {
        get
        {
            return isEnd;
        }
        set
        {
            if (value == true)
            {
                GameObject endOverlay = new GameObject("End Overlay");
                endOverlay.transform.parent = this.transform;
                endOverlay.transform.localPosition = new Vector3(0, 0, 0);
                SpriteRenderer endRenderer = endOverlay.AddComponent<SpriteRenderer>();
                endRenderer.sortingOrder = 1;
                Sprite endSprite = Resources.Load<Sprite>("Flag");
                endRenderer.sprite = endSprite;
            }
            isEnd = value;
        }
    }

    void Awake()
    {
        highlight = this.transform.Find("Highlight").gameObject;
        highlightAnimator = highlight.GetComponent<Animator>();
    }

    void Start()
    {
        if (LevelScript.Instance != null)
        {
            player = LevelScript.Instance.player;
            if (player != null) playerScript = player.GetComponent<PlayerCharacterScript>();
            turnLogic = LevelScript.Instance.turnLogic;
            if (turnLogic != null) turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
            traversableTiles = LevelScript.Instance.traversableTiles;
            if (traversableTiles != null) traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        }
    }

    public void OnTileClicked()
    {
        if (!isHighlighted)
        {
            return;
        }
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnMove:
                playerScript.MoveTo(this.transform.position);
                Keyboard keyboard = Keyboard.current;
                if (keyboard.leftCtrlKey.isPressed || keyboard.rightCtrlKey.isPressed)
                {
                    turnLogicScript.overrideSkipAttackStep = true;
                }
                turnLogicScript.hasMoved = true;
                break;
            case TurnLogicScript.GameState.PlayerTurnAttack:
                GameObject skillUsed = turnLogicScript.skillUsed;
                if (skillUsed == null)
                {
                    return;
                }
                Skill skillScript = skillUsed.GetComponent<Skill>();
                skillScript.UseSkill(this.transform.position, player);
                break;
        }
    }
}
