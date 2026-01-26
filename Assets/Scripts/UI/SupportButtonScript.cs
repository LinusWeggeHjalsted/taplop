using UnityEngine;
using UnityEngine.UI;

public class SupportButtonScript : MonoBehaviour
{
    Button button;
    GameObject supportMenuPrefab;
    GameObject supportMenu;

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayMenuSound();
        if (supportMenu == null)
        {
            // close New Game Menu if it's open
            GameObject newGameMenu = GameObject.Find("New Game Menu(Clone)");
            if (newGameMenu != null)
            {
                Destroy(newGameMenu);
            }
            supportMenu = Instantiate(supportMenuPrefab, this.transform.parent.parent);
        }
        else
        {
            DestroyImmediate(supportMenu);
        }
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        supportMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/Support Menu");
    }
}
