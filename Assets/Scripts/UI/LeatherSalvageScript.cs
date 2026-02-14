using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class LeatherSalvageScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform salvageRectTransform;
    public Transform canvas;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public void OnPointerEnter(PointerEventData eventData)
    {
        Vector3[] salvageCorners = new Vector3[4];
        salvageRectTransform.GetWorldCorners(salvageCorners);
        Vector3 salvageTopRightPosition = salvageCorners[2];
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
            tooltipRectTransform.pivot = new Vector2(0, 1f);
            tooltipRectTransform.position = salvageTopRightPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            StartCoroutine(tooltipScript.SetText("Leather", ""));
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    void Awake()
    {
        salvageRectTransform = this.GetComponent<RectTransform>();
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }

    void Start()
    {
        canvas = GameReferences.GetCanvasTransform();
    }
}
