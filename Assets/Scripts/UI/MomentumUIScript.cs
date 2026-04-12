using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using TMPro;

public class MomentumUIScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform momentumRectTransform;
    public TextMeshProUGUI momentumText;
    public Transform canvas;
    public GameObject player;
    public EntityScript playerScript;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    void Awake()
    {
        momentumRectTransform = this.GetComponent<RectTransform>();
        momentumText = this.transform.Find("Momentum Text").GetComponent<TextMeshProUGUI>();
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }

    void Start()
    {
        canvas = GameReferences.GetCanvasTransform();
        player = LevelScript.Instance.player;
        playerScript = player.GetComponent<EntityScript>();
    }

    public void OnPointerEnter(PointerEventData eventData)
    {
        // refresh canvas reference if it was destroyed
        if (canvas == null)
        {
            canvas = GameReferences.GetCanvasTransform();
        }
        Vector3[] buttonCorners = new Vector3[4];
        momentumRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonTopLeftPosition = buttonCorners[1];
        Transform tooltipTransform = canvas.Find("Tooltip");
        if (tooltipTransform != null)
        {
            tooltip = tooltipTransform.gameObject;
        }
        if (tooltip == null)
        {
            tooltip = Instantiate(tooltipPrefab, canvas);
            tooltip.name = "Tooltip";
            tooltip.transform.SetAsLastSibling();
        }
        if (tooltip != null)
        {
            RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
            tooltipRectTransform.pivot = new Vector2(0, 0);
            tooltipRectTransform.position = buttonTopLeftPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            StartCoroutine(tooltipScript.SetText($"{playerScript.Momentum} Momentum", $"+{playerScript.convertedMomentum} damage"));
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    public void UpdateMomentum()
    {
        momentumText.text = playerScript.Momentum.ToString();
    }
}
